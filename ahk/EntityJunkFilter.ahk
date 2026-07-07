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
    global g_junkPatDisabled, g_junkCustom, g_junkActive, g_reader
    out := []
    for _, cat in _JunkFilterCategoryDefs()
        for _, p in cat["patterns"]
            if !g_junkPatDisabled.Has(p)
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
    global g_junkFilterEnabled, g_junkPatDisabled, g_junkCustom
    k := String(key)
    isOn := (value = 1 || value = "1" || value = true)
    if (k = "enabled")
        g_junkFilterEnabled := isOn
    else if (SubStr(k, 1, 4) = "cat:")
    {
        ck := SubStr(k, 5)
        for _, cat in _JunkFilterCategoryDefs()
            if (cat["key"] = ck)
            {
                for _, p in cat["patterns"]
                {
                    if (isOn)
                        (g_junkPatDisabled.Has(p) && g_junkPatDisabled.Delete(p))
                    else
                        g_junkPatDisabled[p] := true
                }
                break
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
; button. Returns: { enabled, custom, categories:[{ key,label,on,patterns:[{p,on}] }] }.
BuildJunkFilterHeaderJson()
{
    global g_junkFilterEnabled, g_junkPatDisabled, g_junkCustom
    json := '{"enabled":' (g_junkFilterEnabled ? "true" : "false")
        . ',"custom":' _JsStr(g_junkCustom)
        . ',"categories":['
    firstCat := true
    for _, cat in _JunkFilterCategoryDefs()
    {
        if !firstCat
            json .= ","
        firstCat := false
        ; "on" = every pattern in the category is enabled (drives enable/disable all).
        catOn := true
        for _, p in cat["patterns"]
            if g_junkPatDisabled.Has(p)
            {
                catOn := false
                break
            }
        json .= '{"key":' _JsStr(cat["key"])
            . ',"label":' _JsStr(cat["label"])
            . ',"on":' (catOn ? "true" : "false")
            . ',"patterns":['
        firstPat := true
        for _, p in cat["patterns"]
        {
            if !firstPat
                json .= ","
            firstPat := false
            patOn := !g_junkPatDisabled.Has(p)
            json .= '{"p":' _JsStr(p) ',"on":' (patOn ? "true" : "false") "}"
        }
        json .= "]}"
    }
    return json "]}"
}

; Persists the junk-filter state to the INI ([JunkFilter]). Disabled built-in
; patterns join with commas (patterns contain none); custom terms store verbatim.
; Blanks write a space so IniRead seeds back. Category state is fully derived
; from the per-pattern disabled set, so there is nothing category-level to store.
SaveEntityJunkFilter()
{
    global g_junkFilterEnabled, g_junkPatDisabled, g_junkCustom, g_junkConfigFile
    f := (g_junkConfigFile != "") ? g_junkConfigFile : (A_ScriptDir "\poeformance_config.ini")
    IniWrite(g_junkFilterEnabled ? "1" : "0", f, "JunkFilter", "enabled")
    dis := ""
    for pat, _ in g_junkPatDisabled
        dis .= (dis = "" ? "" : ",") pat
    IniWrite((dis = "" ? " " : dis), f, "JunkFilter", "disabledPatterns")
    IniWrite((g_junkCustom = "" ? " " : g_junkCustom), f, "JunkFilter", "custom")
}

; Loads the junk-filter state from the INI. Seeds ALL globals unconditionally
; first (module-init gotcha: defaults ON, all categories ON), then overlays any
; saved values. Finishes by precomputing the active pattern list.
LoadEntityJunkFilter()
{
    global g_junkFilterEnabled, g_junkPatDisabled, g_junkCustom, g_junkActive, g_junkConfigFile
    g_junkConfigFile := A_ScriptDir "\poeformance_config.ini"
    g_junkFilterEnabled := true
    g_junkPatDisabled := Map()
    g_junkCustom := ""
    g_junkActive := []

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

    RebuildJunkActive()
}
