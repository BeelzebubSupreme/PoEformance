; PoeTradeSession.ahk
; Tier-2 transport for the trade-API unique pricing: a dedicated WebView2 window navigated
; to the official PoE2 trade site. The trade search/fetch run as SAME-ORIGIN fetch() calls
; *inside* that logged-in browser context, so the request carries the browser's own cookies
; (POESESSID / cf_clearance), User-Agent and TLS fingerprint — Cloudflare is satisfied and no
; secret ever leaves the browser (nothing is read into AHK, nothing is written to disk by us;
; the session lives only in the WebView2 user-data folder, which is gitignored).
;
; Flow: AHK posts {cmd:"tradeQuery", id, name, league} to the page; an injected helper runs
; the 2-step trade query (search -> fetch) and posts back {id, ok, status, listings:[...]}.
; LootTradePricing.ahk drives the queue + converts listings to Exalted + caches the result.
;
; Globals are seeded in LoadPoeTradeSession() (NOT via top-level initializers — AHK v2
; module-init gotcha; this file is #Include'd at the bottom). Included by InGameStateMonitor.

; Seeds the session-window globals. Called once at startup.
LoadPoeTradeSession()
{
    global g_poeTradeWin := 0          ; WebViewGui instance (0 = not open)
    global g_poeTradeReady := false    ; injected helper signalled ready on a PoE page
    global g_poeTradeUserDir := A_ScriptDir "\config\wv2_poe"   ; isolated, gitignored profile
    global g_poeTradeHidden := false   ; window hidden to background (object alive, queries still run)
}

; True when the trade session window exists (created). The page may still be on the Cloudflare
; / login interstitial — readiness for queries is g_poeTradeReady.
PoeTradeSessionOpen()
{
    global g_poeTradeWin
    return (IsSet(g_poeTradeWin) && IsObject(g_poeTradeWin))
}

PoeTradeSessionReady()
{
    global g_poeTradeReady
    return (IsSet(g_poeTradeReady) && g_poeTradeReady)
}

; Hides the trade window to the background WITHOUT closing it. The WebView2 object stays alive
; (we never call TrySuspendAsync), so its same-origin fetch() queries keep running — window
; visibility only governs rendering, not script execution. Re-shown via PoeTradeSessionShow.
PoeTradeSessionHide()
{
    global g_poeTradeWin, g_poeTradeHidden
    if !PoeTradeSessionOpen()
        return
    try g_poeTradeWin.Hide()
    g_poeTradeHidden := true
    try SetTimer(PushHeaderToWebView, -50)
}

; True when the session window exists but is currently hidden to the background.
PoeTradeSessionHidden()
{
    global g_poeTradeHidden
    return (PoeTradeSessionOpen() && IsSet(g_poeTradeHidden) && g_poeTradeHidden)
}

; Opens (or focuses) the trade session window and navigates it to the PoE2 trade search page
; for the league. The user logs in / passes Cloudflare once; the session persists in the
; gitignored profile folder. Safe to call repeatedly.
PoeTradeSessionShow(league)
{
    global g_poeTradeWin, g_poeTradeReady, g_poeTradeUserDir, g_poeTradeHidden
    league := (league != "") ? league : "Standard"
    url := "https://www.pathofexile.com/trade2/search/poe2/" league

    if PoeTradeSessionOpen()
    {
        try {
            g_poeTradeWin.Show()
            WinActivate("ahk_id " g_poeTradeWin.Hwnd)
        }
        g_poeTradeHidden := false
        try SetTimer(PushHeaderToWebView, -50)
        return
    }

    dir := g_poeTradeUserDir
    if !DirExist(dir)
        try DirCreate(dir)

    try {
        ; Create blank first so the document-created script is registered BEFORE navigation
        ; (so the helper is present on the very first PoE page load).
        win := WebViewGui("+Resize +MinSize640x480", "PoEformance — PoE Trade (sign in)", ,
            { DefaultWidth: 1000, DefaultHeight: 820, DataDir: dir })
        ctrl := win.Control
        ctrl.WebMessageReceived(_PoeTradeOnMessage)
        try ctrl.wv.AddScriptToExecuteOnDocumentCreatedAsync(_PoeTradeHelperJs()).await()
        win.OnEvent("Close", (*) => _PoeTradeOnClose())
        g_poeTradeWin := win
        g_poeTradeReady := false
        g_poeTradeHidden := false
        win.Show()
        ctrl.Navigate(url)
    } catch as ex {
        g_poeTradeWin := 0
        g_poeTradeReady := false
        LogError("PoeTradeSessionShow", ex)
    }
}

; Sends a query to the page helper. Returns true if posted. id correlates the async reply.
PoeTradeSend(id, name, league)
{
    global g_poeTradeWin
    if !PoeTradeSessionOpen()
        return false
    league := (league != "") ? league : "Standard"
    j := '{"cmd":"tradeQuery","id":' (id + 0) ',"name":' _PoeTradeJStr(name) ',"league":' _PoeTradeJStr(league) "}"
    try {
        g_poeTradeWin.Control.wv.PostWebMessageAsJson(j)
        return true
    } catch as ex {
        LogError("PoeTradeSend", ex)
        return false
    }
}

; Closes the session window (the login stays cached in the profile folder).
PoeTradeSessionClose()
{
    global g_poeTradeWin, g_poeTradeReady, g_poeTradeHidden
    if PoeTradeSessionOpen()
        try g_poeTradeWin.Destroy()
    g_poeTradeWin := 0
    g_poeTradeReady := false
    g_poeTradeHidden := false
}

_PoeTradeOnClose()
{
    global g_poeTradeWin, g_poeTradeReady, g_poeTradeHidden
    g_poeTradeWin := 0
    g_poeTradeReady := false
    g_poeTradeHidden := false
    try SetTimer(PushHeaderToWebView, -50)
}

; WebMessageReceived handler for the trade window. Routes the helper-ready signal and query
; results (delegated to LootTradePricing for conversion + caching).
_PoeTradeOnMessage(wv, args, *)
{
    global g_poeTradeReady
    try {
        data := JsonFull_Parse(args.WebMessageAsJson)
        if !(IsObject(data))
            return
        if (data.Has("cmd") && data["cmd"] = "tradeHelperReady")
        {
            g_poeTradeReady := true
            try SetTimer(_LtTradeDrain, -200)
            try SetTimer(PushHeaderToWebView, -50)
            return
        }
        if data.Has("id")
        {
            id := Integer(data["id"])
            ok := data.Has("ok") && data["ok"]
            status := data.Has("status") ? Integer(data["status"]) : 0
            listings := (data.Has("listings") && Type(data["listings"]) = "Array") ? data["listings"] : []
            err := data.Has("error") ? data["error"] : ""
            _LtTradeOnResult(id, ok, status, listings, err)
        }
    } catch as ex {
        LogError("_PoeTradeOnMessage", ex)
    }
}

; Minimal JSON string encoder.
_PoeTradeJStr(s)
{
    s := s ""
    s := StrReplace(s, "\", "\\")
    s := StrReplace(s, '"', '\"')
    s := StrReplace(s, "`r", " ")
    s := StrReplace(s, "`n", " ")
    s := StrReplace(s, "`t", " ")
    return '"' s '"'
}

; The page-side helper, injected on every document. Listens for {cmd:"tradeQuery"} messages,
; runs the same-origin 2-step trade query, and posts back {id, ok, status, listings|error}.
; Built line-by-line (NOT an AHK continuation section) so no JS line can accidentally close it.
_PoeTradeHelperJs()
{
    lines := [
        "(function(){",
        "  if (window.__poeTradeHelper) return; window.__poeTradeHelper = 1;",
        "  function post(o){ try { window.chrome.webview.postMessage(o); } catch(e){} }",
        "  window.chrome.webview.addEventListener('message', async function(e){",
        "    var m = e.data; if (!m || m.cmd !== 'tradeQuery') return;",
        "    try {",
        "      var sUrl = '/api/trade2/search/poe2/' + encodeURIComponent(m.league);",
        "      var body = JSON.stringify({query:{status:{option:'online'},name:m.name},sort:{price:'asc'}});",
        "      var sRes = await fetch(sUrl,{method:'POST',headers:{'content-type':'application/json'},credentials:'include',body:body});",
        "      if (!sRes.ok){ post({id:m.id,ok:false,status:sRes.status,error:'search'}); return; }",
        "      var sData = await sRes.json();",
        "      var ids = (sData.result||[]).slice(0,10);",
        "      if (!sData.id || ids.length===0){ post({id:m.id,ok:true,status:200,listings:[]}); return; }",
        "      var fUrl = '/api/trade2/fetch/' + ids.join(',') + '?query=' + sData.id + '&realm=poe2';",
        "      var fRes = await fetch(fUrl,{credentials:'include'});",
        "      if (!fRes.ok){ post({id:m.id,ok:false,status:fRes.status,error:'fetch'}); return; }",
        "      var fData = await fRes.json();",
        "      var listings = (fData.result||[]).map(function(r){ return (r&&r.listing&&r.listing.price)?{amount:r.listing.price.amount,currency:r.listing.price.currency}:null; }).filter(Boolean);",
        "      post({id:m.id,ok:true,status:200,listings:listings});",
        "    } catch(err){ post({id:m.id,ok:false,status:0,error:String(err)}); }",
        "  });",
        "  post({cmd:'tradeHelperReady'});",
        "})();"
    ]
    out := ""
    for ln in lines
        out .= ln "`n"
    return out
}
