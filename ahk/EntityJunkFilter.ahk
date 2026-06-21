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
; Detailed management: a master switch, five category toggles, per-pattern
; toggles inside each category, plus a free-form list of user "custom" terms.
; The active pattern list is precomputed on every change (RebuildJunkActive) so
; the per-entity hot path is just a short InStr loop. Self-persists to
; poeformance_config.ini [JunkFilter] (same pattern as Groups/Alerts). Included
; via TreeViewWatchlistPanel.ahk; LoadEntityJunkFilter() seeds all globals.

global g_junkFilterEnabled := true     ; master switch
global g_junkCatEnabled    := Map()    ; categoryKey -> bool
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

; Recomputes g_junkActive from the enabled categories (minus individually
; disabled patterns) plus the parsed custom terms. Called after every config
; change so IsJunkEntity never re-evaluates toggles per entity. Returns nothing.
RebuildJunkActive()
{
    global g_junkCatEnabled, g_junkPatDisabled, g_junkCustom, g_junkActive
    out := []
    for _, cat in _JunkFilterCategoryDefs()
    {
        if !(g_junkCatEnabled.Has(cat["key"]) && g_junkCatEnabled[cat["key"]])
            continue
        for _, p in cat["patterns"]
            if !g_junkPatDisabled.Has(p)
                out.Push(p)
    }
    for _, term in StrSplit(g_junkCustom, ",")
    {
        t := Trim(term)
        if (t != "")
            out.Push(t)
    }
    g_junkActive := out
}

; Applies a single setting from the web UI (BridgeDispatch "SetJunk"). key forms:
; "enabled" | "cat:<key>" | "pat:<pattern>" | "custom". value is 1/0 for the
; toggles, or the raw string for "custom". Rebuilds the active list afterwards.
_ApplyJunkSetting(key, value)
{
    global g_junkFilterEnabled, g_junkCatEnabled, g_junkPatDisabled, g_junkCustom
    k := String(key)
    isOn := (value = 1 || value = "1" || value = true)
    if (k = "enabled")
        g_junkFilterEnabled := isOn
    else if (SubStr(k, 1, 4) = "cat:")
        g_junkCatEnabled[SubStr(k, 5)] := isOn
    else if (SubStr(k, 1, 4) = "pat:")
    {
        pat := SubStr(k, 5)
        if (isOn)
            g_junkPatDisabled.Delete(pat)
        else
            g_junkPatDisabled[pat] := true
    }
    else if (k = "custom")
        g_junkCustom := String(value)
    RebuildJunkActive()
}

; Builds the "junkFilter" JSON object for the header push so the Filters tab
; mirrors the saved master/category/pattern/custom state. Returns a JSON object
; string: { enabled, custom, categories:[{ key,label,on,patterns:[{p,on}] }] }.
BuildJunkFilterHeaderJson()
{
    global g_junkFilterEnabled, g_junkCatEnabled, g_junkPatDisabled, g_junkCustom
    json := '{"enabled":' (g_junkFilterEnabled ? "true" : "false")
        . ',"custom":' _JsStr(g_junkCustom)
        . ',"categories":['
    firstCat := true
    for _, cat in _JunkFilterCategoryDefs()
    {
        if !firstCat
            json .= ","
        firstCat := false
        catOn := (g_junkCatEnabled.Has(cat["key"]) && g_junkCatEnabled[cat["key"]])
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

; Persists the junk-filter state to the INI ([JunkFilter]). Category flags are
; one key each; disabled built-in patterns join with commas (patterns contain
; none); custom terms store verbatim. Blanks write a space so IniRead seeds back.
SaveEntityJunkFilter()
{
    global g_junkFilterEnabled, g_junkCatEnabled, g_junkPatDisabled, g_junkCustom, g_junkConfigFile
    f := (g_junkConfigFile != "") ? g_junkConfigFile : (A_ScriptDir "\poeformance_config.ini")
    IniWrite(g_junkFilterEnabled ? "1" : "0", f, "JunkFilter", "enabled")
    for _, cat in _JunkFilterCategoryDefs()
    {
        on := (g_junkCatEnabled.Has(cat["key"]) && g_junkCatEnabled[cat["key"]])
        IniWrite(on ? "1" : "0", f, "JunkFilter", "cat_" cat["key"])
    }
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
    global g_junkFilterEnabled, g_junkCatEnabled, g_junkPatDisabled, g_junkCustom, g_junkActive, g_junkConfigFile
    g_junkConfigFile := A_ScriptDir "\poeformance_config.ini"
    g_junkFilterEnabled := true
    g_junkCatEnabled := Map()
    for _, cat in _JunkFilterCategoryDefs()
        g_junkCatEnabled[cat["key"]] := true
    g_junkPatDisabled := Map()
    g_junkCustom := ""
    g_junkActive := []

    f := g_junkConfigFile
    en := IniRead(f, "JunkFilter", "enabled", "")
    if (en != "")
        g_junkFilterEnabled := (en = "1")
    for _, cat in _JunkFilterCategoryDefs()
    {
        v := IniRead(f, "JunkFilter", "cat_" cat["key"], "")
        if (v != "")
            g_junkCatEnabled[cat["key"]] := (v = "1")
    }
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
