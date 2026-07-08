; EntityJunkFilter.ahk
; Global path-based "junk" entity suppressor. Hides gameplay-irrelevant nodes
; (cosmetic asset nodes, engine FX/material definitions, invisible daemons,
; pets/clones, decorator markers) from EVERY consumer of the entity sample —
; the radar, the Entities browser, the Game-tab trees, exports and the AutoPilot
; target picker — via a case-insensitive substring match on the entity metadata
; path. Hooked once at the sample chokepoint (CollectEntityMapCandidates).
;
; Pattern set ported from the upstream C# JunkFilter (reconciled 2026-05-31 from
; POE2Radar JunkFilter.cs + entity_database_analysis.md). The over-broad
; "weapons/" pattern is deliberately omitted (it would hide real weapon items).
;
; Detailed management: a master switch, per-pattern toggles grouped into
; categories (each category has no gate of its own, just an "enable/disable all"
; bulk button), plus a free-form list of user "custom" terms. The active pattern list is precomputed
; on every change (RebuildJunkActive) so the per-entity hot path is just a short
; InStr loop. Self-persists to poeformance_config.ini [JunkFilter] (same pattern
; as Groups/Alerts). Included via TreeViewWatchlistPanel.ahk; LoadEntityJunkFilter()
; seeds all globals.

global g_junkFilterEnabled := true     ; master switch
global g_junkPatDisabled   := Map()    ; built-in pattern -> true (individually off)
global g_junkCustom        := ""       ; raw comma-separated user terms
global g_junkActive        := []       ; precomputed flat list of active patterns
global g_junkConfigFile    := ""
; User-extensible categories: custom patterns can be filed under a built-in OR a
; user-created category (e.g. add the meta-group "LeagueIncursionNew" under a new
; "MiscellaneousObjects" category from the Entity Inspector). g_junkCatCustom maps
; a category key -> ordered array of custom pattern strings; g_junkUserCats maps a
; user-created category key -> its display label (built-ins keep their def label).
global g_junkUserCats  := Map()        ; userKey(lower) -> label
global g_junkCatCustom := Map()        ; catKey(lower)  -> [pattern, …]

; Static built-in category + pattern definitions (never mutated). The order
; defines the UI order. Each entry: Map{ key, label, patterns[] }. See the C#
; reference for the per-category rationale (why each class of node is junk).
_JunkFilterCategoryDefs()
{
    return [
        Map("key", "cosmetic", "label", "Visual / cosmetic asset nodes",
            "patterns", ["/attachments", "microtransactions", "/timelines/", "stashskins", "hairstyles", "/outfits/"]),
        Map("key", "engine", "label", "Engine asset / effect definitions",
            "patterns", ["/fx/", "/mat/", "/ao/", "/epk/", "/graph/", "/audio/", "/environment/"]),
        Map("key", "daemon", "label", "Invisible daemon / modifier entities",
            "patterns", ["monstermods", "essencemoddaemons", "tormentedspirits", "/daemon/"]),
        Map("key", "pets", "label", "Pets / clones / summon base classes",
            "patterns", ["/pet/", "/clone/", "playersummoned"]),
        Map("key", "markers", "label", "Already-handled / decorator markers",
            "patterns", ["bossroomminimapicon", "/runemarked"]),
        Map("key", "hideout", "label", "Hideout decoration doodads",
            "patterns", ["hideoutdoodad"])
    ]
}

; True if a category key is one of the built-in definitions.
_JunkIsBuiltinCat(key)
{
    for _, cat in _JunkFilterCategoryDefs()
        if (cat["key"] = key)
            return true
    return false
}

; Resolves a built-in category's display label, or "" when unknown.
_JunkBuiltinLabel(key)
{
    for _, cat in _JunkFilterCategoryDefs()
        if (cat["key"] = key)
            return cat["label"]
    return ""
}

; True if the entity path matches any ACTIVE junk pattern (case-insensitive
; substring). Cheap hot-path call: a master-switch short-circuit, then an InStr
; loop over the precomputed active list. Param: entityPath. Returns: bool.
IsJunkEntity(entityPath)
{
    global g_junkFilterEnabled, g_junkActive
    if (!g_junkFilterEnabled || entityPath = "")
        return false
    for _, p in g_junkActive
        if InStr(entityPath, p, false)
            return true
    return false
}

; Recomputes g_junkActive from every category's patterns (minus the individually
; disabled ones) plus the parsed custom terms. Called after every config change
; so IsJunkEntity never re-evaluates toggles per entity. Returns nothing.
RebuildJunkActive()
{
    global g_junkPatDisabled, g_junkCustom, g_junkActive, g_junkCatCustom, g_reader
    out := []
    for _, cat in _JunkFilterCategoryDefs()
        for _, p in cat["patterns"]
            if !g_junkPatDisabled.Has(p)
                out.Push(p)
    ; Per-category custom patterns (built-in AND user categories) — toggled off
    ; via the same g_junkPatDisabled set, deleted via catpatdel.
    for _, pats in g_junkCatCustom
        for _, p in pats
            if (p != "" && !g_junkPatDisabled.Has(p))
                out.Push(p)
    for _, term in StrSplit(g_junkCustom, ",")
    {
        t := Trim(term)
        if (t != "")
            out.Push(t)
    }
    g_junkActive := out
    ; The radar hot path keeps a per-entity "known junk" id cache (skips re-decoding junk every
    ; tick). It reflects the patterns active AT decision time, so a filter change must drop it —
    ; otherwise entities the user just un-junked would stay hidden (and vice-versa).
    if (IsSet(g_reader) && IsObject(g_reader) && g_reader.HasOwnProp("_radarJunkIds"))
        g_reader._radarJunkIds := Map()
}

; Applies a single setting from the web UI (BridgeDispatch "SetJunk"). key forms:
; "enabled" | "cat:<key>" | "pat:<pattern>" | "custom". Categories have no gate of
; their own — "cat:<key>" is just a bulk shortcut that enables (1) or disables (0)
; EVERY pattern in that category at once (the per-category "enable/disable all"
; button). value is 1/0 for the toggles, or the raw string for "custom". Rebuilds
; the active list afterwards.
_ApplyJunkSetting(key, value)
{
    global g_junkFilterEnabled, g_junkPatDisabled, g_junkCustom, g_junkUserCats, g_junkCatCustom
    k := String(key)
    isOn := (value = 1 || value = "1" || value = true)
    ; Bridge field delimiter for the multi-field keys (catadd/catpatdel/newcat).
    ; "|" is safe: it never appears in metadata paths, lowercased category keys,
    ; or category labels — and it avoids round-tripping a control char through the
    ; WebView postMessage/JSON bridge. (INI persistence uses RS/US separately.)
    SEP := "|"
    if (k = "enabled")
        g_junkFilterEnabled := isOn
    ; Add a custom pattern under a category. value = "<catKey>|<label>|<pattern>".
    ; Auto-creates the user category when the key is neither built-in nor already
    ; known. Case-insensitive dedup on the pattern.
    else if (k = "catadd")
    {
        parts := StrSplit(value, SEP)
        ck  := (parts.Length >= 1) ? Trim(StrLower(parts[1])) : ""
        lbl := (parts.Length >= 2) ? Trim(parts[2]) : ""
        pat := (parts.Length >= 3) ? Trim(parts[3]) : ""
        if (ck != "" && pat != "")
        {
            if (!_JunkIsBuiltinCat(ck) && !g_junkUserCats.Has(ck))
                g_junkUserCats[ck] := (lbl != "" ? lbl : ck)
            if !g_junkCatCustom.Has(ck)
                g_junkCatCustom[ck] := []
            exists := false
            for _, p in g_junkCatCustom[ck]
                if (StrLower(p) = StrLower(pat))
                {
                    exists := true
                    break
                }
            if !exists
                g_junkCatCustom[ck].Push(pat)
            ; A freshly added pattern is active — clear any stale disabled flag.
            (g_junkPatDisabled.Has(pat) && g_junkPatDisabled.Delete(pat))
        }
    }
    ; Remove one custom pattern. value = "<catKey>|<pattern>". Drops an emptied
    ; USER category entirely (built-ins persist even with no custom patterns).
    else if (k = "catpatdel")
    {
        parts := StrSplit(value, SEP)
        ck  := (parts.Length >= 1) ? Trim(StrLower(parts[1])) : ""
        pat := (parts.Length >= 2) ? Trim(parts[2]) : ""
        if (ck != "" && g_junkCatCustom.Has(ck))
        {
            kept := []
            for _, p in g_junkCatCustom[ck]
                if (StrLower(p) != StrLower(pat))
                    kept.Push(p)
            g_junkCatCustom[ck] := kept
            (g_junkPatDisabled.Has(pat) && g_junkPatDisabled.Delete(pat))
            if (kept.Length = 0 && g_junkUserCats.Has(ck))
            {
                g_junkUserCats.Delete(ck)
                g_junkCatCustom.Delete(ck)
            }
        }
    }
    ; Create an empty user category. value = "<catKey>|<label>".
    else if (k = "newcat")
    {
        parts := StrSplit(value, SEP)
        ck  := (parts.Length >= 1) ? Trim(StrLower(parts[1])) : ""
        lbl := (parts.Length >= 2) ? Trim(parts[2]) : ""
        if (ck != "" && !_JunkIsBuiltinCat(ck) && !g_junkUserCats.Has(ck))
        {
            g_junkUserCats[ck] := (lbl != "" ? lbl : ck)
            if !g_junkCatCustom.Has(ck)
                g_junkCatCustom[ck] := []
        }
    }
    ; Delete a whole USER category (+ its patterns). Built-ins are not deletable.
    else if (k = "catdel")
    {
        ck := Trim(StrLower(String(value)))
        if (ck != "" && g_junkUserCats.Has(ck))
        {
            if g_junkCatCustom.Has(ck)
            {
                for _, p in g_junkCatCustom[ck]
                    (g_junkPatDisabled.Has(p) && g_junkPatDisabled.Delete(p))
                g_junkCatCustom.Delete(ck)
            }
            g_junkUserCats.Delete(ck)
        }
    }
    else if (SubStr(k, 1, 4) = "cat:")
    {
        ck := SubStr(k, 5)
        toggleList := []
        for _, cat in _JunkFilterCategoryDefs()
            if (cat["key"] = ck)
            {
                for _, p in cat["patterns"]
                    toggleList.Push(p)
                break
            }
        ; Include the category's custom patterns (built-in AND user categories),
        ; so "enable/disable all" also flips user-added patterns.
        if g_junkCatCustom.Has(ck)
            for _, p in g_junkCatCustom[ck]
                toggleList.Push(p)
        for _, p in toggleList
        {
            if (isOn)
                (g_junkPatDisabled.Has(p) && g_junkPatDisabled.Delete(p))
            else
                g_junkPatDisabled[p] := true
        }
    }
    else if (SubStr(k, 1, 4) = "pat:")
    {
        pat := SubStr(k, 5)
        if (isOn)
            (g_junkPatDisabled.Has(pat) && g_junkPatDisabled.Delete(pat))
        else
            g_junkPatDisabled[pat] := true
    }
    else if (k = "custom")
        g_junkCustom := String(value)
    RebuildJunkActive()
}

; Builds the "junkFilter" JSON object for the header push so the Filters tab
; mirrors the saved master/pattern/custom state. Per category, "on" is the
; computed "all patterns enabled" flag — it drives the "enable/disable all"
; button; "custom" carries the user-added per-category patterns (each deletable),
; and "user":true marks a user-created category (deletable as a whole). Returns:
; { enabled, custom, categories:[{ key,label,on,user,patterns:[{p,on}],custom:[{p,on}] }] }.
BuildJunkFilterHeaderJson()
{
    global g_junkFilterEnabled, g_junkPatDisabled, g_junkCustom, g_junkUserCats, g_junkCatCustom
    json := '{"enabled":' (g_junkFilterEnabled ? "true" : "false")
        . ',"custom":' _JsStr(g_junkCustom)
        . ',"categories":['
    firstCat := true
    ; Built-in categories first (in def order), then user-created ones.
    for _, cat in _JunkFilterCategoryDefs()
    {
        if !firstCat
            json .= ","
        firstCat := false
        json .= _JunkCatJson(cat["key"], cat["label"], cat["patterns"], false)
    }
    for ck, lbl in g_junkUserCats
    {
        if !firstCat
            json .= ","
        firstCat := false
        json .= _JunkCatJson(ck, lbl, [], true)
    }
    return json "]}"
}

; Serializes one junk category to JSON (built-in patterns + user custom patterns).
;   ck/lbl   — category key + display label
;   builtins — the fixed built-in pattern array ([] for user categories)
;   isUser   — true for a user-created category (adds "user":true, deletable)
_JunkCatJson(ck, lbl, builtins, isUser)
{
    global g_junkPatDisabled, g_junkCatCustom
    ; "on" (enable/disable-all) covers built-in AND custom patterns.
    catOn := true
    for _, p in builtins
        if g_junkPatDisabled.Has(p)
        {
            catOn := false
            break
        }
    customPats := g_junkCatCustom.Has(ck) ? g_junkCatCustom[ck] : []
    if catOn
        for _, p in customPats
            if g_junkPatDisabled.Has(p)
            {
                catOn := false
                break
            }
    json := '{"key":' _JsStr(ck)
        . ',"label":' _JsStr(lbl)
        . ',"on":' (catOn ? "true" : "false")
        . ',"user":' (isUser ? "true" : "false")
        . ',"patterns":['
    firstPat := true
    for _, p in builtins
    {
        if !firstPat
            json .= ","
        firstPat := false
        json .= '{"p":' _JsStr(p) ',"on":' (!g_junkPatDisabled.Has(p) ? "true" : "false") "}"
    }
    json .= '],"custom":['
    firstPat := true
    for _, p in customPats
    {
        if !firstPat
            json .= ","
        firstPat := false
        json .= '{"p":' _JsStr(p) ',"on":' (!g_junkPatDisabled.Has(p) ? "true" : "false") "}"
    }
    return json "]}"
}

; Persists the junk-filter state to the INI ([JunkFilter]). Disabled built-in
; patterns join with commas (patterns contain none); custom terms store verbatim.
; Blanks write a space so IniRead seeds back. Category state is fully derived
; from the per-pattern disabled set, so there is nothing category-level to store.
SaveEntityJunkFilter()
{
    global g_junkFilterEnabled, g_junkPatDisabled, g_junkCustom, g_junkUserCats, g_junkCatCustom, g_junkConfigFile
    f := (g_junkConfigFile != "") ? g_junkConfigFile : (A_ScriptDir "\poeformance_config.ini")
    IniWrite(g_junkFilterEnabled ? "1" : "0", f, "JunkFilter", "enabled")
    dis := ""
    for pat, _ in g_junkPatDisabled
        dis .= (dis = "" ? "" : ",") pat
    IniWrite((dis = "" ? " " : dis), f, "JunkFilter", "disabledPatterns")
    IniWrite((g_junkCustom = "" ? " " : g_junkCustom), f, "JunkFilter", "custom")

    ; Per-category custom patterns + user categories. One record per category
    ; (RS-separated); each record = catKey US label US pat1 US pat2 … . Both
    ; user categories and built-in categories that gained custom patterns persist.
    RS := Chr(30), US := Chr(31)
    keys := Map()
    for ck, _ in g_junkUserCats
        keys[ck] := true
    for ck, _ in g_junkCatCustom
        keys[ck] := true
    ser := ""
    for ck, _ in keys
    {
        lbl := g_junkUserCats.Has(ck) ? g_junkUserCats[ck] : ""
        entry := ck US lbl
        if g_junkCatCustom.Has(ck)
            for _, p in g_junkCatCustom[ck]
                entry .= US p
        ser .= (ser = "" ? "" : RS) entry
    }
    IniWrite((ser = "" ? " " : ser), f, "JunkFilter", "catPatterns")
}

; Loads the junk-filter state from the INI. Seeds ALL globals unconditionally
; first (module-init gotcha: defaults ON, all categories ON), then overlays any
; saved values. Finishes by precomputing the active pattern list.
LoadEntityJunkFilter()
{
    global g_junkFilterEnabled, g_junkPatDisabled, g_junkCustom, g_junkActive, g_junkConfigFile
    global g_junkUserCats, g_junkCatCustom
    g_junkConfigFile := A_ScriptDir "\poeformance_config.ini"
    g_junkFilterEnabled := true
    g_junkPatDisabled := Map()
    g_junkCustom := ""
    g_junkActive := []
    g_junkUserCats := Map()
    g_junkCatCustom := Map()

    f := g_junkConfigFile
    en := IniRead(f, "JunkFilter", "enabled", "")
    if (en != "")
        g_junkFilterEnabled := (en = "1")
    dis := IniRead(f, "JunkFilter", "disabledPatterns", "")
    if (dis != "" && dis != " ")
    {
        for _, p in StrSplit(dis, ",")
            if (Trim(p) != "")
                g_junkPatDisabled[Trim(p)] := true
    }
    cust := IniRead(f, "JunkFilter", "custom", "")
    if (cust != "" && cust != " ")
        g_junkCustom := cust

    ; Per-category custom patterns + user categories (see SaveEntityJunkFilter).
    cp := IniRead(f, "JunkFilter", "catPatterns", "")
    if (cp != "" && cp != " ")
    {
        for _, entry in StrSplit(cp, Chr(30))
        {
            if (entry = "")
                continue
            parts := StrSplit(entry, Chr(31))
            ck := (parts.Length >= 1) ? Trim(StrLower(parts[1])) : ""
            if (ck = "")
                continue
            lbl := (parts.Length >= 2) ? parts[2] : ""
            pats := []
            i := 3
            while (i <= parts.Length)
            {
                if (Trim(parts[i]) != "")
                    pats.Push(parts[i])
                i++
            }
            if !_JunkIsBuiltinCat(ck)
                g_junkUserCats[ck] := (lbl != "" ? lbl : ck)
            g_junkCatCustom[ck] := pats
        }
    }

    RebuildJunkActive()
}
