; SkillBarReader.ahk
; Reads the live skill-bar key bindings straight from the HUD UI tree, using the
; per-element Displayed Text (UiElementBase.TextPtr @ 0x390). This is the reliable
; source the poe2_production_Config.ini parse could not provide: each keyboard skill
; slot's hotkey label (e.g. "Q","R","E","T","F") is read from the rendered UI.
;
; skills_bar layout confirmed live 2026-06-21 against a subtree dump:
;   skills_bar (HUD > HUDRight > skills_bar)
;     -> per-slot icon containers (direct children, ~64x64 UI units)
;          visible container = an equipped, shown slot
;          hidden  container = the weapon-set-2 duplicate (label "Ctrl+<key>")
;        each container holds, a few levels deeper, the slot's label leaf whose
;        Displayed Text is the bound key. There are two rows:
;          top row    = mouse-bound slots (label-less): slot 1 = Left Mouse always,
;                       slot 2 = Middle Mouse, slot 3 = Right Mouse (when label empty)
;          bottom row = keyboard slots, read directly from the label text.
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
; leaf carrying NON-EMPTY Displayed Text — that text is the bound key. Hidden
; subtrees are pruned (so a hidden weapon-set-2 container never leaks its "Ctrl+…"
; label), and empty visible leaves are skipped (so a mouse slot returns "").
; Params: ptr - subtree root; depth - recursion guard. Returns the key, or "".
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
; mouse buttons "LButton"/…, "Ctrl+Q") is passed through trimmed. Param: t - label.
_SkillBarNormalizeKey(t)
{
    t := Trim(t)
    if (StrLen(t) = 1 && RegExMatch(t, "^[A-Za-z]$"))
        return StrLower(t)
    return t
}

; Reads the skill-bar bindings. Param: reader - the PoE2MemoryReader.
; Returns an array of slot Maps in row-major order (top->bottom, left->right):
;   { slot, key, sendKey, screenX, screenY, addr }
; slot is the 1-based row-major index; the top (mouse) row gets the LMB/MMB/RMB
; treatment. Empty when the bar isn't available / visible.
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

    ; Gather the actual skill-slot containers: VISIBLE and icon-sized (~64x64 UI
    ; units). This INCLUDES the label-less mouse slots (top row) and excludes both
    ; the hidden weapon-set-2 duplicates (not visible) and the wide indicator panel.
    slots := []
    Loop n
    {
        container := NumGet(buf.Ptr, (A_Index - 1) * A_PtrSize, "Ptr")
        if !reader.IsProbablyValidPointer(container)
            continue
        flags := 0
        try flags := reader.Mem.ReadUInt(container + PoE2Offsets.UiElementBase["Flags"])
        if (((flags >> 11) & 1) = 0)
            continue
        szBuf := reader.Mem.ReadBytes(container + PoE2Offsets.UiElementBase["UnscaledSize"], 8)
        if !szBuf
            continue
        sw := NumGet(szBuf.Ptr, 0, "Float")
        sh := NumGet(szBuf.Ptr, 4, "Float")
        if (sw < 40 || sw > 96 || sh < 40 || sh > 96)
            continue
        key := _SkillBarFindLabel(reader, container, 0)
        pos := UiTree_GetScreenPos(reader, container)
        slots.Push(Map("key", key, "sx", pos["x"], "sy", pos["y"], "addr", container))
    }
    if (slots.Length = 0)
        return out
    _SkillBarSortRowMajor(slots)

    ; Top row = the mouse-bound slots. Slot 1 is ALWAYS the left mouse button;
    ; slots 2 and 3 fall back to the middle / right mouse button when their label
    ; is empty (a mouse bind renders no text). Only applied when a distinct lower
    ; (keyboard) row exists, so a single-row bar isn't mistaken for mouse slots.
    topY := slots[1]["sy"]
    for s in slots
        if (s["sy"] < topY)
            topY := s["sy"]
    hasBottom := false
    for s in slots
        if (s["sy"] - topY > 16)
            hasBottom := true

    for i, s in slots
    {
        key := s["key"]
        isTop := (Abs(s["sy"] - topY) <= 8)
        if (hasBottom && isTop)
        {
            if (i = 1)
                key := "LButton"                 ; slot 1 is always Left Mouse
            else if (i = 2 && key = "")
                key := "MButton"                 ; slot 2 -> Middle Mouse when label-less
            else if (i = 3 && key = "")
                key := "RButton"                 ; slot 3 -> Right Mouse when label-less
        }
        out.Push(Map(
            "slot", i,
            "key", key,
            "sendKey", _SkillBarNormalizeKey(key),
            "screenX", s["sx"],
            "screenY", s["sy"],
            "addr", s["addr"]
        ))
    }
    return out
}

; In-place insertion sort of the gathered slot array by (sy, sx). Small N.
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
    dy := a["sy"] - b["sy"]
    if (Abs(dy) > 8)
        return dy > 0
    return a["sx"] > b["sx"]
}

; Resolves the local player entity pointer from the cached radar snapshot.
; Returns the pointer, or 0 when unavailable.
_SkillBarLocalPlayerPtr()
{
    global g_radarLastSnap
    snap := (g_radarLastSnap && g_radarLastSnap is Map) ? g_radarLastSnap : 0
    if !snap
        return 0
    inGs := snap.Has("inGameState") ? snap["inGameState"] : 0
    area := (inGs && inGs is Map && inGs.Has("areaInstance")) ? inGs["areaInstance"] : 0
    return (area && area is Map && area.Has("localPlayerPtr")) ? area["localPlayerPtr"] : 0
}

; Reads the skill bar AND resolves each slot's assigned skill via the slot's
; ActiveSkill pointer (slot + SkillBarSlot.ActiveSkillPtr -> detailsPtr), then
; cross-references the player's decoded skills (keyed by detailsPtr) for the
; name + icon. Param: reader - the PoE2MemoryReader. Returns the
; ReadSkillBarHotkeys() array, each slot Map additionally carrying "skillName"
; (display name), "skillInternal", and "iconPath" ("" when unresolved).
ReadSkillBarSkills(reader)
{
    slots := ReadSkillBarHotkeys(reader)
    if (slots.Length = 0)
        return slots
    byDetails := Map()
    lpPtr := _SkillBarLocalPlayerPtr()
    if lpPtr
    {
        skillsData := 0
        try skillsData := reader.ReadPlayerSkills(lpPtr)
        if (skillsData && skillsData is Map && skillsData.Has("skills"))
        {
            for sk in skillsData["skills"]
            {
                if !(sk is Map)
                    continue
                dp := sk.Has("detailsPtr") ? sk["detailsPtr"] : 0
                if (dp)
                    byDetails[dp] := sk
            }
        }
    }
    for s in slots
    {
        s["skillName"]     := ""
        s["skillInternal"] := ""
        s["iconPath"]      := ""
        dp := 0
        try dp := reader.Mem.ReadPtr(s["addr"] + PoE2Offsets.SkillBarSlot["ActiveSkillPtr"])
        if (dp && byDetails.Has(dp))
        {
            sk := byDetails[dp]
            s["skillInternal"] := sk.Has("name") ? sk["name"] : ""
            s["skillName"]     := (sk.Has("displayName") && sk["displayName"] != "") ? sk["displayName"] : s["skillInternal"]
            s["iconPath"]      := sk.Has("iconPath") ? sk["iconPath"] : ""
        }
    }
    return slots
}

; Reads the skill bar and (re)populates g_skillKeyBySlot (slot -> key) plus the
; skill-name maps g_skillKeyBySkillName (display + internal name -> key) and
; g_skillSlotSkillName (slot -> display name). Non-destructive when the bar yields
; nothing (keeps the existing maps), so it never wipes binds while the bar is
; hidden / between areas. Does NOT push to the UI — callers do that.
; Returns the number of bound slots.
RefreshSkillBarKeys()
{
    global g_reader, g_skillKeyBySlot, g_skillKeyLoadStatus
    global g_skillKeyBySkillName, g_skillSlotSkillName
    if !IsObject(g_reader)
        return 0
    list := ReadSkillBarSkills(g_reader)
    if (list.Length = 0)
        return 0
    bySlot   := Map()
    byName   := Map()
    slotName := Map()
    cnt := 0
    for e in list
    {
        sk := e["sendKey"]
        if (sk = "")
            continue
        bySlot[e["slot"]] := sk
        cnt += 1
        nm    := e.Has("skillName") ? e["skillName"] : ""
        intnm := e.Has("skillInternal") ? e["skillInternal"] : ""
        if (nm != "")
        {
            byName[StrLower(nm)] := sk
            slotName[e["slot"]]  := nm
        }
        if (intnm != "")
            byName[StrLower(intnm)] := sk
    }
    if (cnt = 0)
        return 0
    g_skillKeyBySlot := bySlot
    ; Only overwrite the name maps when skills actually resolved, so a transient
    ; unreadable-skills tick doesn't drop a previously good name->key mapping.
    if (byName.Count > 0)
    {
        g_skillKeyBySkillName := byName
        g_skillSlotSkillName  := slotName
    }
    g_skillKeyLoadStatus := "ui:" cnt
    return cnt
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
    list := ReadSkillBarSkills(g_reader)
    if (list.Length = 0)
    {
        try MsgBox("No skill slots detected.`n`nMake sure you are in a zone with the skill bar visible and skills equipped, then try again.", "Detect Skill Keys", 0x30)
        return
    }
    RefreshSkillBarKeys()
    try PushHotkeyBindingsToWebView()
    txt := "Detected " list.Length " skill slot(s) — row-major (top->bottom, left->right):`n`n"
    for e in list
    {
        lbl := (e["key"] != "") ? e["key"] : "(unbound)"
        snd := (e["sendKey"] != "") ? e["sendKey"] : "-"
        skn := (e.Has("skillName") && e["skillName"] != "") ? e["skillName"] : "?"
        txt .= "  slot " e["slot"] ":  " lbl "  ->  " skn "   (send: " snd ")`n"
    }
    txt .= "`nApplied to the Hotkeys-tab skill slots (key + skill name)."
    try MsgBox(txt, "Detect Skill Keys", 0x40)
}

; ── Skill <-> Slot link discovery (RE diagnostic) ───────────────────────────
; Goal: map a skill NAME to its skill-bar SLOT automatically. Each player skill
; exposes several stable pointers (the ActiveSkill struct = detailsPtr, the
; GrantedEffectsPerLevel row = geplRow, and the ActiveSkills DAT row) plus its
; Icon_DDSFile path. The skill-bar slot must reference its skill somehow; this
; probe scans each slot's subtree for a pointer field whose value equals one of
; those known skill pointers, which would give a clean, offset-based link.
; Writes a report to debug\skill_slot_link_*.txt and shows its path.
DiagSkillSlotLink()
{
    global g_reader, g_radarLastSnap
    if !IsObject(g_reader)
    {
        try MsgBox("Game not connected.", "Skill<->Slot Link", 0x10)
        return
    }

    ; Resolve the local player and read its skills (name + the linkable pointers).
    snap := (g_radarLastSnap && g_radarLastSnap is Map) ? g_radarLastSnap : 0
    lpPtr := 0
    if snap
    {
        inGs := snap.Has("inGameState") ? snap["inGameState"] : 0
        area := (inGs && inGs is Map && inGs.Has("areaInstance")) ? inGs["areaInstance"] : 0
        lpPtr := (area && area is Map && area.Has("localPlayerPtr")) ? area["localPlayerPtr"] : 0
    }
    skillsData := 0
    if lpPtr
        try skillsData := g_reader.ReadPlayerSkills(lpPtr)
    skills := (skillsData && skillsData is Map && skillsData.Has("skills")) ? skillsData["skills"] : []

    ; Build pointer -> "name (which-pointer)" map and a printable skill table.
    ptrMap := Map()
    skillLines := []
    for sk in skills
    {
        if !(sk is Map)
            continue
        nm := (sk.Has("displayName") && sk["displayName"] != "") ? sk["displayName"]
            : (sk.Has("name") ? sk["name"] : "?")
        dp := sk.Has("detailsPtr") ? sk["detailsPtr"] : 0
        gr := sk.Has("geplRow") ? sk["geplRow"] : 0
        dat := 0
        if (dp && g_reader.IsProbablyValidPointer(dp))
            try dat := g_reader.Mem.ReadPtr(dp + PoE2Offsets.ActiveSkillDetails["ActiveSkillsDatPtr"])
        ip := sk.Has("iconPath") ? sk["iconPath"] : ""
        if (dp)
            ptrMap[dp] := nm " (detailsPtr)"
        if (gr)
            ptrMap[gr] := nm " (geplRow)"
        if (dat)
            ptrMap[dat] := nm " (activeSkillsDat)"
        skillLines.Push(Format("  {} | details=0x{:X} gepl=0x{:X} dat=0x{:X}`n     icon={}", nm, dp, gr, dat, ip))
    }

    slots := ReadSkillBarHotkeys(g_reader)

    rpt := "Skill <-> Slot link probe`n`n"
    rpt .= "Skills (" skills.Length "):`n"
    for ln in skillLines
        rpt .= ln "`n"
    rpt .= "`nSlots (" slots.Length "):`n"
    for e in slots
    {
        rpt .= Format("`nslot {} key='{}' addr=0x{:X}`n", e["slot"], e["key"], e["addr"])
        matches := _SkillBarScanPtrMatches(g_reader, e["addr"], ptrMap)
        if (matches.Length = 0)
            rpt .= "   (no skill-pointer match found in subtree)`n"
        else
            for mln in matches
                rpt .= "   " mln "`n"
    }

    outDir := A_ScriptDir "\debug"
    if !DirExist(outDir)
        DirCreate(outDir)
    outPath := outDir "\skill_slot_link_" FormatTime(A_Now, "yyyyMMdd_HHmmss") ".txt"
    try FileAppend(rpt, outPath, "UTF-8")
    try MsgBox("Skill<->Slot link probe written to:`n" outPath "`n`nSkills: " skills.Length "   Slots: " slots.Length, "Skill<->Slot Link", 0x40)
}

; Bounded subtree scan of a skill-bar slot for pointer fields whose value matches
; a known skill pointer. Params: rootPtr - slot container; ptrMap - value->label.
; Returns an array of human-readable match lines.
_SkillBarScanPtrMatches(reader, rootPtr, ptrMap)
{
    out := []
    if !reader.IsProbablyValidPointer(rootPtr)
        return out
    queue := [{ptr: rootPtr, d: 0}]
    seen := Map()
    nodes := 0
    while (queue.Length > 0 && nodes < 200)
    {
        it := queue.RemoveAt(1)
        p := it.ptr
        if (seen.Has(p) || !reader.IsProbablyValidPointer(p))
            continue
        seen[p] := true
        nodes += 1
        blk := reader.Mem.ReadBytes(p, 0x600)
        if blk
        {
            off := 0
            while (off + A_PtrSize <= 0x600)
            {
                v := NumGet(blk.Ptr, off, "Ptr")
                if (ptrMap.Has(v))
                    out.Push(Format("MATCH @+0x{:03X} (node 0x{:X}): {} = 0x{:X}", off, p, ptrMap[v], v))
                off += 8
            }
        }
        if (it.d < 5)
        {
            chdr := reader.Mem.ReadBytes(p, 0x20)
            if chdr
            {
                cf := NumGet(chdr.Ptr, 0x10, "Ptr")
                cl := NumGet(chdr.Ptr, 0x18, "Ptr")
                if (reader.IsProbablyValidPointer(cf) && cl > cf)
                {
                    cn := Min((cl - cf) // A_PtrSize, 64)
                    cbuf := reader.Mem.ReadBytes(cf, cn * A_PtrSize)
                    if cbuf
                    {
                        Loop cn
                        {
                            cp := NumGet(cbuf.Ptr, (A_Index - 1) * A_PtrSize, "Ptr")
                            if reader.IsProbablyValidPointer(cp)
                                queue.Push({ptr: cp, d: it.d + 1})
                        }
                    }
                }
            }
        }
    }
    return out
}
