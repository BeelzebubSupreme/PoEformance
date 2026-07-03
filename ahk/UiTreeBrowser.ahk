; UiTreeBrowser.ahk
; Recursive UI element tree walker and navigator

; Dump entire UI tree starting from gameUiPtr to a TSV file.
; Returns: path to written file, or "" on error.
UiTree_Dump(reader, gameUiPtr, maxDepth := 12, outPath := "")
{
    if (!IsObject(reader) || !reader.IsProbablyValidPointer(gameUiPtr))
        return ""
    if (outPath = "")
    {
        debugDir := A_ScriptDir "\debug"
        if !DirExist(debugDir)
            DirCreate(debugDir)
        stamp := FormatTime(, "yyyyMMdd_HHmmss")
        outPath := debugDir "\ui_tree_" stamp ".tsv"
    }
    header := "Depth`tPath`tStringId`tAddress`tVisible`tChildCount`tScreenX`tScreenY`tSizeW`tSizeH`tFlags`tText`n"
    queue   := [{ptr: gameUiPtr, depth: 0, parentPath: ""}]
    rows    := []
    visited := Map()
    deadline := A_TickCount + 20000
    while (queue.Length > 0)
    {
        if (A_TickCount > deadline)
            break
        item     := queue.RemoveAt(1)
        elemPtr  := item.ptr
        depth    := item.depth
        parentPath := item.parentPath
        if (visited.Has(elemPtr))
            continue
        visited[elemPtr] := true
        elem := UiTree_ReadElement(reader, elemPtr)
        if !elem
            continue
        stringId   := elem["stringId"]
        childCount := elem["childCount"]
        if (stringId != "")
            myPath := (parentPath = "") ? stringId : parentPath " > " stringId
        else
            myPath := parentPath
        rows.Push(
            depth . "`t"
            . myPath . "`t"
            . stringId . "`t"
            . Format("0x{:X}", elemPtr) . "`t"
            . (elem["isVisible"] ? "1" : "0") . "`t"
            . childCount . "`t"
            . Round(elem["screenX"], 1) . "`t"
            . Round(elem["screenY"], 1) . "`t"
            . Round(elem["sizeW"], 1) . "`t"
            . Round(elem["sizeH"], 1) . "`t"
            . Format("0x{:08X}", elem["flags"]) . "`t"
            ; Sanitize so embedded tabs/newlines never break the TSV layout.
            . StrReplace(StrReplace(StrReplace(elem["text"], "`t", " "), "`r", " "), "`n", " ")
        )
        if (depth < maxDepth && childCount > 0)
        {
            childFirst := elem["childFirst"]
            childLast  := elem["childLast"]
            if (reader.IsProbablyValidPointer(childFirst) && childLast > childFirst)
            {
                numChildren := Min((childLast - childFirst) // A_PtrSize, 512)
                ptrBuf := reader.Mem.ReadBytes(childFirst, numChildren * A_PtrSize)
                if ptrBuf
                {
                    Loop numChildren
                    {
                        childPtr := NumGet(ptrBuf.Ptr, (A_Index - 1) * A_PtrSize, "Ptr")
                        if (reader.IsProbablyValidPointer(childPtr) && !visited.Has(childPtr))
                            queue.Push({ptr: childPtr, depth: depth + 1, parentPath: myPath})
                    }
                }
            }
        }
    }
    try
    {
        content := header
        for _, row in rows
            content .= row . "`n"
        FileAppend(content, outPath, "UTF-8")
        return outPath
    }
    catch
        return ""
}

; Read all properties of a single UI element in one batch RPM call.
; Returns: Map with all properties, or 0 on invalid pointer.
UiTree_ReadElement(reader, elemPtr)
{
    if (!IsObject(reader) || !reader.IsProbablyValidPointer(elemPtr))
        return 0
    headerSize := 0x2A0
    hdr := reader.Mem.ReadBytes(elemPtr, headerSize)
    if !hdr
        return 0
    childFirst := NumGet(hdr.Ptr, PoE2Offsets.UiElementBase["ChildrenFirst"], "Ptr")
    childLast  := NumGet(hdr.Ptr, PoE2Offsets.UiElementBase["ChildrenLast"], "Ptr")
    childCount := 0
    if (reader.IsProbablyValidPointer(childFirst) && childLast > childFirst)
        childCount := Min((childLast - childFirst) // A_PtrSize, 4096)
    parentPtr  := NumGet(hdr.Ptr, PoE2Offsets.UiElementBase["ParentPtr"], "Ptr")
    relX       := NumGet(hdr.Ptr, PoE2Offsets.UiElementBase["RelativePosition"], "Float")
    relY       := NumGet(hdr.Ptr, PoE2Offsets.UiElementBase["RelativePosition"] + 0x04, "Float")
    localMult  := NumGet(hdr.Ptr, PoE2Offsets.UiElementBase["LocalScaleMultiplier"], "Float")
    scaleIndex := NumGet(hdr.Ptr, PoE2Offsets.UiElementBase["ScaleIndex"], "UChar")
    stringId   := reader.ReadStdWStringAt(elemPtr + PoE2Offsets.UiElementBase["StringIdPtr"])
    fontName   := reader.ReadStdWStringAt(elemPtr + PoE2Offsets.UiElementBase["FontNamePtr"])
    textStyle  := reader.ReadStdWStringAt(elemPtr + PoE2Offsets.UiElementBase["TextStylePtr"])
    text       := reader.ReadStdWStringAt(elemPtr + PoE2Offsets.UiElementBase["TextPtr"], 256)
    flags      := NumGet(hdr.Ptr, PoE2Offsets.UiElementBase["Flags"], "UInt")
    isVisible  := ((flags >> 11) & 1) ? true : false
    sizeW      := NumGet(hdr.Ptr, PoE2Offsets.UiElementBase["UnscaledSize"], "Float")
    sizeH      := NumGet(hdr.Ptr, PoE2Offsets.UiElementBase["UnscaledSize"] + 0x04, "Float")
    posModX    := NumGet(hdr.Ptr, PoE2Offsets.UiElementBase["PositionModifier"], "Float")
    posModY    := NumGet(hdr.Ptr, PoE2Offsets.UiElementBase["PositionModifier"] + 0x04, "Float")
    vtable     := NumGet(hdr.Ptr, 0x000, "Ptr")   ; vtable pointer — not a named UiElementBase field
    ; BackgroundColor — 4 floats (RGBA, normalized 0..1)
    bgR        := NumGet(hdr.Ptr, PoE2Offsets.UiElementBase["BackgroundColor"] + 0x00, "Float")
    bgG        := NumGet(hdr.Ptr, PoE2Offsets.UiElementBase["BackgroundColor"] + 0x04, "Float")
    bgB        := NumGet(hdr.Ptr, PoE2Offsets.UiElementBase["BackgroundColor"] + 0x08, "Float")
    bgA        := NumGet(hdr.Ptr, PoE2Offsets.UiElementBase["BackgroundColor"] + 0x0C, "Float")
    bgPacked   := _UiPackColor(bgR, bgG, bgB, bgA)
    shouldModifyPos := ((flags >> 10) & 1) ? true : false
    return Map(
        "address",         elemPtr,
        "stringId",        stringId,
        "fontName",        fontName,
        "textStyle",       textStyle,
        "text",            text,
        "isVisible",       isVisible,
        "shouldModifyPos", shouldModifyPos,
        "flags",           flags,
        "childCount",      childCount,
        "childFirst",      childFirst,
        "childLast",       childLast,
        "parentPtr",       parentPtr,
        "relX",            relX,
        "relY",            relY,
        "screenX",         relX,
        "screenY",         relY,
        "sizeW",           sizeW,
        "sizeH",           sizeH,
        "localMult",       localMult,
        "scaleIndex",      scaleIndex,
        "posModX",         posModX,
        "posModY",         posModY,
        "vtable",          vtable,
        "bgColor",         bgPacked
    )
}

; Packs four normalized floats (0..1) into an RRGGBBAA hex uint.
_UiPackColor(r, g, b, a)
{
    ri := Min(255, Max(0, Round(r * 255)))
    gi := Min(255, Max(0, Round(g * 255)))
    bi := Min(255, Max(0, Round(b * 255)))
    ai := Min(255, Max(0, Round(a * 255)))
    return (ri << 24) | (gi << 16) | (bi << 8) | ai
}

; True iff the element AND every ancestor (walked up via Parent +0xB8) have the
; local visible bit (bit 11) set — i.e. it's actually shown, not just locally
; flagged (an element can have its own bit set while a hidden parent keeps it
; off-screen). Cheap: one small read per level, capped at 16. Stops at rootPtr
; (when given) or a self-referencing parent. Ported from the community C#
; HierarchicallyVisible helper. Returns false on any read failure (fail-safe).
UiTree_HierarchicallyVisible(reader, elemPtr, rootPtr := 0)
{
    if (!IsObject(reader) || !reader.IsProbablyValidPointer(elemPtr))
        return false
    flagsOff  := PoE2Offsets.UiElementBase["Flags"]
    parentOff := PoE2Offsets.UiElementBase["ParentPtr"]
    cur := elemPtr
    guard := 0
    while (reader.IsProbablyValidPointer(cur) && guard < 16)
    {
        guard += 1
        fl := reader.Mem.ReadUInt(cur + flagsOff)
        if (((fl >> 11) & 1) = 0)
            return false
        if (rootPtr && cur = rootPtr)
            break
        par := reader.Mem.ReadPtr(cur + parentOff)
        if (par = cur)
            break
        cur := par
    }
    return true
}

; Walks up from elemPtr through parent pointers until rootPtr (or hitting NULL),
; finding each step's index in its parent's children array.
; Returns: Array of integers like [1, 41, 1] (root → element).
UiTree_GetIndexPath(reader, rootPtr, elemPtr)
{
    path := []
    if (!IsObject(reader) || !reader.IsProbablyValidPointer(elemPtr))
        return path
    cur := elemPtr
    Loop 32
    {
        if (cur = rootPtr || !reader.IsProbablyValidPointer(cur))
            break
        hdr := reader.Mem.ReadBytes(cur, 0xC0)
        if !hdr
            break
        parent := NumGet(hdr.Ptr, PoE2Offsets.UiElementBase["ParentPtr"], "Ptr")
        if (!reader.IsProbablyValidPointer(parent))
            break
        ; Read parent's child array to find cur's index
        phdr := reader.Mem.ReadBytes(parent, 0x20)
        if !phdr
            break
        cFirst := NumGet(phdr.Ptr, PoE2Offsets.UiElementBase["ChildrenFirst"], "Ptr")
        cLast  := NumGet(phdr.Ptr, PoE2Offsets.UiElementBase["ChildrenLast"], "Ptr")
        if (!reader.IsProbablyValidPointer(cFirst) || cLast <= cFirst)
            break
        n := Min((cLast - cFirst) // A_PtrSize, 4096)
        buf := reader.Mem.ReadBytes(cFirst, n * A_PtrSize)
        if !buf
            break
        idx := -1
        Loop n
        {
            cp := NumGet(buf.Ptr, (A_Index - 1) * A_PtrSize, "Ptr")
            if (cp = cur)
            {
                idx := A_Index - 1
                break
            }
        }
        if (idx < 0)
            break
        path.InsertAt(1, idx)
        cur := parent
    }
    return path
}

; Navigate by StringId path like "LeftPanel > InventoryPanel"
; or index path like "[0] > [3]"
; Returns: address of found element, or 0.
UiTree_FindByPath(reader, gameUiPtr, pathString)
{
    if (!IsObject(reader) || !reader.IsProbablyValidPointer(gameUiPtr) || pathString = "")
        return 0
    segments := StrSplit(pathString, " > ")
    currentPtr := gameUiPtr
    for _, segment in segments
    {
        segment := Trim(segment)
        if (segment = "")
            continue
        if (SubStr(segment, 1, 1) = "[" && SubStr(segment, -1) = "]")
        {
            idx := Integer(SubStr(segment, 2, StrLen(segment) - 2))
            currentPtr := UiTree_GetChildByIndex(reader, currentPtr, idx)
        }
        else
            currentPtr := UiTree_GetChildByStringId(reader, currentPtr, segment)
        if !reader.IsProbablyValidPointer(currentPtr)
            return 0
    }
    return currentPtr
}

; Find child by StringId.
UiTree_GetChildByStringId(reader, elemPtr, targetId)
{
    if (!reader.IsProbablyValidPointer(elemPtr))
        return 0
    hdr := reader.Mem.ReadBytes(elemPtr, 0x20)
    if !hdr
        return 0
    childFirst := NumGet(hdr.Ptr, PoE2Offsets.UiElementBase["ChildrenFirst"], "Ptr")
    childLast  := NumGet(hdr.Ptr, PoE2Offsets.UiElementBase["ChildrenLast"], "Ptr")
    if (!reader.IsProbablyValidPointer(childFirst) || childLast <= childFirst)
        return 0
    numChildren := Min((childLast - childFirst) // A_PtrSize, 512)
    ptrBuf := reader.Mem.ReadBytes(childFirst, numChildren * A_PtrSize)
    if !ptrBuf
        return 0
    Loop numChildren
    {
        childPtr := NumGet(ptrBuf.Ptr, (A_Index - 1) * A_PtrSize, "Ptr")
        if !reader.IsProbablyValidPointer(childPtr)
            continue
        sid := reader.ReadStdWStringAt(childPtr + PoE2Offsets.UiElementBase["StringIdPtr"])
        if (sid = targetId)
            return childPtr
    }
    return 0
}

; Find child by index (0-based).
UiTree_GetChildByIndex(reader, elemPtr, idx)
{
    if (!reader.IsProbablyValidPointer(elemPtr))
        return 0
    hdr := reader.Mem.ReadBytes(elemPtr, 0x20)
    if !hdr
        return 0
    childFirst := NumGet(hdr.Ptr, PoE2Offsets.UiElementBase["ChildrenFirst"], "Ptr")
    childLast  := NumGet(hdr.Ptr, PoE2Offsets.UiElementBase["ChildrenLast"], "Ptr")
    if (!reader.IsProbablyValidPointer(childFirst) || childLast <= childFirst)
        return 0
    numChildren := (childLast - childFirst) // A_PtrSize
    if (idx < 0 || idx >= numChildren)
        return 0
    ptrBuf := reader.Mem.ReadBytes(childFirst + idx * A_PtrSize, A_PtrSize)
    return ptrBuf ? NumGet(ptrBuf.Ptr, 0, "Ptr") : 0
}

; ── UI-space → screen-pixel conversion (port of GameHelper2 GameWindowScale +
; GameCull) ───────────────────────────────────────────────────────────────────
; The game lays its UI out on a 2560×1600 design canvas. Two axis scales exist:
; v1 = (clientW - 2*cull)/2560 (width) and v2 = clientH/1600 (height); each
; element's ScaleIndex picks its pair: 1→(v1,v1), 2→(v2,v2), 3→(v1,v2), else
; (1,1) — always × the element's LocalScaleMultiplier. cull is the letterbox
; bar width in px the game computes for wide aspect ratios (an int at the
; "GameCullSize" static address; screen X additionally shifts right by +cull).
; Returns Map(x,y,w,h [client area in ABSOLUTE screen px], cull, v1, v2) or 0.
UiTree_ScaleCtx(reader, gameHwnd := 0)
{
    if !gameHwnd
        try gameHwnd := ResolvePoEWindow()
    cr := gameHwnd ? NavClientRect(gameHwnd) : 0
    if !IsObject(cr)
        return 0
    cull := 0
    try {
        if (IsObject(reader) && reader.StaticAddresses.Has("GameCullSize"))
            cull := reader.Mem.ReadInt(reader.StaticAddresses["GameCullSize"])
    }
    if !(cull > 0 && cull * 2 < cr["w"])   ; sanity: bars can never cover the window
        cull := 0
    v2 := cr["h"] / 1600.0
    v1 := (cr["w"] - 2 * cull) / 2560.0
    ; Plausibility band: the width scale can only deviate a little from the
    ; height scale (2560×1600 design; wide aspects are letterbox-CULLED back
    ; toward it, narrow ones squeeze mildly). A v1 far outside the band means
    ; the cull read is garbage (the GameCullSize static was never consumed
    ; before this feature, so a mis-resolved pattern was invisible until now)
    ; — distrust the cull first, then fall back to the uniform height scale.
    if (v2 > 0 && (v1 < 0.7 * v2 || v1 > 1.3 * v2))
    {
        cull := 0
        v1 := cr["w"] / 2560.0
        if (v1 < 0.7 * v2 || v1 > 1.3 * v2)
            v1 := v2   ; extreme aspect — behave like the proven uniform scale
    }
    cr["cull"] := cull
    cr["v1"]   := v1
    cr["v2"]   := v2
    return cr
}

; Per-element [wScale, hScale] for a (ScaleIndex, LocalScaleMultiplier) pair
; under scale context sc — GameHelper2 GameWindowScale.GetScaleValue, hardened
; against stale/garbage memory reads: the ScaleIndex/LocalScaleMultiplier
; offsets (0x18A/0x130) come from the 0.4.x reference layout and other fields
; HAVE drifted in 0.5.x (StringId 0x140→0x098), so an implausible multiplier
; (≤0 / huge) degrades to 1.0 and an unknown index degrades to the uniform
; height scale (v2,v2) — the proven pre-scale-aware behavior — instead of raw
; pixels (the C# default), so a bad read can never collapse or inflate a rect.
_UiScalePair(scaleIndex, localMult, sc)
{
    ; Legacy-uniform override (set by the UiTree_HitTest fallback): ignore the
    ; per-element scale data entirely — the exact pre-scale-aware behavior.
    if (sc.Has("uniform") && sc["uniform"])
        return [sc["v2"], sc["v2"]]
    m := (localMult > 0.2 && localMult < 5.0) ? localMult : 1.0
    if (scaleIndex = 1)
        return [m * sc["v1"], m * sc["v1"]]
    if (scaleIndex = 2)
        return [m * sc["v2"], m * sc["v2"]]
    if (scaleIndex = 3)
        return [m * sc["v1"], m * sc["v2"]]
    return [m * sc["v2"], m * sc["v2"]]
}

; Get exact position by walking the parent chain — a faithful port of the C#
; reference (GameHelper2 UiElementBase.GetUnScaledPosition): each child adds its
; relativePosition (+ the parent's positionModifier when the child's
; ShouldModifyPos flag is set), and when parent and child live in DIFFERENT
; scale spaces (ScaleIndex / LocalScaleMultiplier differ) the accumulated
; position converts between them per axis (pos * parentScale / childScale).
; Returns Map(x, y [unscaled, in the LEAF element's scale space], scaleIndex,
; localMult [the leaf's own — needed to scale the result to pixels]). Params:
; reader, elemPtr, sc — optional UiTree_ScaleCtx (built on demand; without a
; resolvable game window the conversion degrades to the old plain sum).
UiTree_GetScreenPos(reader, elemPtr, sc := 0)
{
    chain := []
    curPtr := elemPtr
    Loop 16 {
        if !reader.IsProbablyValidPointer(curPtr)
            break
        hdr := reader.Mem.ReadBytes(curPtr, 0x200)
        if !hdr
            break
        chain.Push(Map(
            "relX",       NumGet(hdr.Ptr, PoE2Offsets.UiElementBase["RelativePosition"], "Float"),
            "relY",       NumGet(hdr.Ptr, PoE2Offsets.UiElementBase["RelativePosition"] + 0x04, "Float"),
            "flags",      NumGet(hdr.Ptr, PoE2Offsets.UiElementBase["Flags"], "UInt"),
            "posModX",    NumGet(hdr.Ptr, PoE2Offsets.UiElementBase["PositionModifier"], "Float"),
            "posModY",    NumGet(hdr.Ptr, PoE2Offsets.UiElementBase["PositionModifier"] + 0x04, "Float"),
            "scaleIndex", NumGet(hdr.Ptr, PoE2Offsets.UiElementBase["ScaleIndex"], "UChar"),
            "localMult",  NumGet(hdr.Ptr, PoE2Offsets.UiElementBase["LocalScaleMultiplier"], "Float")))
        parentP := NumGet(hdr.Ptr, PoE2Offsets.UiElementBase["ParentPtr"], "Ptr")
        if !reader.IsProbablyValidPointer(parentP)
            break
        curPtr := parentP
    }
    N := chain.Length
    if (N = 0)
        return Map("x", 0.0, "y", 0.0, "scaleIndex", 0, "localMult", 1.0)
    if !IsObject(sc)
        sc := UiTree_ScaleCtx(reader)
    accX := chain[N]["relX"]
    accY := chain[N]["relY"]
    Loop N - 1 {
        childIdx  := N - A_Index
        parentIdx := childIdx + 1
        child  := chain[childIdx]
        parent := chain[parentIdx]
        if (child["flags"] >> 10) & 1 {
            accX += parent["posModX"]
            accY += parent["posModY"]
        }
        ; Scale-space conversion (reference: parentPos * parentScale / childScale).
        if (IsObject(sc) && (parent["scaleIndex"] != child["scaleIndex"]
                          || parent["localMult"] != child["localMult"])) {
            pPair := _UiScalePair(parent["scaleIndex"], parent["localMult"], sc)
            cPair := _UiScalePair(child["scaleIndex"],  child["localMult"],  sc)
            if (cPair[1] != 0 && cPair[2] != 0) {
                accX := accX * pPair[1] / cPair[1]
                accY := accY * pPair[2] / cPair[2]
            }
        }
        accX += child["relX"]
        accY += child["relY"]
    }
    return Map("x", accX, "y", accY,
               "scaleIndex", chain[1]["scaleIndex"], "localMult", chain[1]["localMult"])
}

; Absolute screen-pixel rect of a UI element — the C# reference's Position/Size:
; unscaled pos (leaf scale space) × the element's OWN per-axis scale, + the cull
; bar on X, + the client-area origin. Params: reader, elemPtr, sc (optional
; UiTree_ScaleCtx), sizeW/sizeH (optional pre-read UnscaledSize — saves one RPM
; read when the caller already has it). Returns Map(x,y,w,h) float screen px | 0.
UiTree_ScreenRectOf(reader, elemPtr, sc := 0, sizeW := "", sizeH := "")
{
    if !IsObject(sc)
        sc := UiTree_ScaleCtx(reader)
    if !IsObject(sc)
        return 0
    sp := UiTree_GetScreenPos(reader, elemPtr, sc)
    pair := _UiScalePair(sp["scaleIndex"], sp["localMult"], sc)
    if (sizeW = "" || sizeH = "")
    {
        sizeW := 0.0, sizeH := 0.0
        szb := 0
        try szb := reader.Mem.ReadBytes(elemPtr + PoE2Offsets.UiElementBase["UnscaledSize"], 8)
        if szb
        {
            sizeW := NumGet(szb.Ptr, 0, "Float")
            sizeH := NumGet(szb.Ptr, 4, "Float")
        }
    }
    return Map(
        "x", sc["x"] + sc["cull"] + sp["x"] * pair[1],
        "y", sc["y"] + sp["y"] * pair[2],
        "w", sizeW * pair[1],
        "h", sizeH * pair[2])
}

; Lean header-only geometry read for hit-testing (no string fields, unlike
; UiTree_ReadElement). Returns Map(relX/relY/sizeW/sizeH/posModX/posModY/visible/
; shouldModify/childFirst/childLast) or 0 if <ptr> isn't a readable element.
_UiHitGeom(reader, ptr)
{
    if !reader.IsProbablyValidPointer(ptr)
        return 0
    h := 0
    try h := reader.Mem.ReadBytes(ptr, 0x2A0)
    if !h
        return 0
    flags := NumGet(h.Ptr, PoE2Offsets.UiElementBase["Flags"], "UInt")
    return Map(
        "relX",        NumGet(h.Ptr, PoE2Offsets.UiElementBase["RelativePosition"], "Float"),
        "relY",        NumGet(h.Ptr, PoE2Offsets.UiElementBase["RelativePosition"] + 0x04, "Float"),
        "sizeW",       NumGet(h.Ptr, PoE2Offsets.UiElementBase["UnscaledSize"], "Float"),
        "sizeH",       NumGet(h.Ptr, PoE2Offsets.UiElementBase["UnscaledSize"] + 0x04, "Float"),
        "posModX",     NumGet(h.Ptr, PoE2Offsets.UiElementBase["PositionModifier"], "Float"),
        "posModY",     NumGet(h.Ptr, PoE2Offsets.UiElementBase["PositionModifier"] + 0x04, "Float"),
        "scaleIndex",  NumGet(h.Ptr, PoE2Offsets.UiElementBase["ScaleIndex"], "UChar"),
        "localMult",   NumGet(h.Ptr, PoE2Offsets.UiElementBase["LocalScaleMultiplier"], "Float"),
        "visible",     ((flags >> 11) & 1) ? 1 : 0,
        "shouldModify",((flags >> 10) & 1) ? 1 : 0,
        "childFirst",  NumGet(h.Ptr, PoE2Offsets.UiElementBase["ChildrenFirst"], "Ptr"),
        "childLast",   NumGet(h.Ptr, PoE2Offsets.UiElementBase["ChildrenLast"], "Ptr"))
}

; Descends the UI tree from <rootPtr>, following the deepest VISIBLE child whose
; SCREEN-PIXEL rect contains the cursor (<px>,<py> in absolute screen px).
; Position accumulation mirrors UiTree_GetScreenPos INCLUDING the per-element
; scale-space conversion; each candidate rect is scaled by the CHILD's own scale
; pair (+cull +client origin) before the containment test, so mixed-scale
; subtrees hit-test correctly. When several visible children contain the point
; the LAST one wins (topmost z-order). Returns an array of element addresses
; root..leaf (the hovered element is last), or [] on failure. Params: reader,
; rootPtr, px, py (screen px), sc (optional UiTree_ScaleCtx), maxDepth.
UiTree_HitTest(reader, rootPtr, px, py, sc := 0, maxDepth := 40)
{
    if !IsObject(sc)
        sc := UiTree_ScaleCtx(reader)
    if !IsObject(sc)
        return []
    path := _UiHitDescend(reader, rootPtr, px, py, sc, maxDepth)
    ; Self-healing fallback: a descent that never left the root means the
    ; scale-aware geometry disagrees with reality (stale ScaleIndex/localMult
    ; offsets, bad cull). Retry ONCE with the legacy uniform height scale; the
    ; "uniform" flag is left ON the caller's sc so its follow-up
    ; UiTree_ScreenRectOf calls use the SAME geometry the hit was found with.
    if (path.Length <= 1 && !(sc.Has("uniform") && sc["uniform"]))
    {
        sc["uniform"] := true
        retry := _UiHitDescend(reader, rootPtr, px, py, sc, maxDepth)
        if (retry.Length > 1)
            return retry
        sc["uniform"] := false   ; nothing there either — plain miss, keep scale-aware mode
    }
    return path
}

; The actual scale-aware descent for UiTree_HitTest (split out so the fallback
; can re-run it under a different scale mode). Same params/return as HitTest.
_UiHitDescend(reader, rootPtr, px, py, sc, maxDepth)
{
    g := _UiHitGeom(reader, rootPtr)
    if !IsObject(g)
        return []
    path := [rootPtr]
    absX := g["relX"], absY := g["relY"]   ; unscaled, in the CURRENT element's scale space
    depth := 0
    while (depth < maxDepth)
    {
        depth += 1
        cf := g["childFirst"], cl := g["childLast"]
        if !(reader.IsProbablyValidPointer(cf) && cl > cf)
            break
        n := Min((cl - cf) // A_PtrSize, 4096)
        pPair := _UiScalePair(g["scaleIndex"], g["localMult"], sc)
        best := 0, bestG := 0, bestAbsX := 0, bestAbsY := 0
        i := 0
        while (i < n)
        {
            childPtr := 0
            try childPtr := reader.Mem.ReadPtr(cf + i * A_PtrSize)
            i += 1
            cg := _UiHitGeom(reader, childPtr)
            if !(IsObject(cg) && cg["visible"] && cg["sizeW"] > 0 && cg["sizeH"] > 0)
                continue
            cAbsX := absX + (cg["shouldModify"] ? g["posModX"] : 0)
            cAbsY := absY + (cg["shouldModify"] ? g["posModY"] : 0)
            cPair := pPair
            if (cg["scaleIndex"] != g["scaleIndex"] || cg["localMult"] != g["localMult"])
            {
                cPair := _UiScalePair(cg["scaleIndex"], cg["localMult"], sc)
                if (cPair[1] != 0 && cPair[2] != 0)
                {
                    cAbsX := cAbsX * pPair[1] / cPair[1]
                    cAbsY := cAbsY * pPair[2] / cPair[2]
                }
            }
            cAbsX += cg["relX"]
            cAbsY += cg["relY"]
            ; Containment test in screen px (child's scale space → pixels).
            sx := sc["x"] + sc["cull"] + cAbsX * cPair[1]
            sy := sc["y"] + cAbsY * cPair[2]
            if (px >= sx && px <= sx + cg["sizeW"] * cPair[1]
             && py >= sy && py <= sy + cg["sizeH"] * cPair[2])
            {
                best := childPtr, bestG := cg, bestAbsX := cAbsX, bestAbsY := cAbsY
            }
        }
        if !best
            break
        path.Push(best)
        g := bestG, absX := bestAbsX, absY := bestAbsY
    }
    return path
}
