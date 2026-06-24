<#
.SYNOPSIS
  Prices PoE2 UNIQUE items via the official Path of Exile 2 trade API (trade2), for the
  value-aware loot radar. Fills the gap poe.ninja leaves on Standard (no unique prices).

.DESCRIPTION
  Runs as a detached child process (like tools\poe_ninja_prices.ps1) so the AHK radar hot
  path is never blocked by the network call. SECURITY-FIRST and deliberately conservative:

    * All secrets (POESESSID, cf_clearance, User-Agent) are read from -AuthFile — they are
      NEVER passed on the command line (so they can't leak via the process list) and are
      NEVER written to the output or any log by this script.
    * Strictly rate-limited: a hard minimum interval between every API call, honours HTTP
      429 Retry-After, and stops on auth/Cloudflare failures instead of hammering.
    * On-demand only: prices just the unique names handed in via -NamesFile (the AHK side
      enqueues only uniques poe.ninja couldn't price, and caches results for a long TTL).

  The PoE2 trade endpoints sit behind Cloudflare. A POESESSID alone is usually NOT enough —
  Cloudflare also wants a cf_clearance cookie obtained by the SAME browser/User-Agent. When
  the request is Cloudflare-blocked the server returns 403 with an HTML body; this script
  detects that and reports status "blocked" so the UI can tell the user to refresh the
  cf_clearance + User-Agent (rather than silently retrying).

  Trade prices are reported per listing in a currency (exalted / divine / chaos / …). They
  are converted to Exalted via poe.ninja's public PoE2 currency exchange (the Divine→Exalted
  rate), which works on every league including Standard.

  Output TSV (UTF-8, tab-separated), written atomically:
    #meta  <epochSeconds>  <status>  <errorsOrEmpty>
    P      <normName>      <exaltedPriceOrEmpty>  <listingCount>  <displayName>
  A P row with an empty price + count 0 is a NEGATIVE result (no listings) — cached too so
  worthless uniques are not re-queried.

.PARAMETER League   PoE2 league slug (e.g. "Standard").
.PARAMETER AuthFile KEY=VALUE file: POESESSID=, CF_CLEARANCE=, USER_AGENT= (gitignored).
.PARAMETER NamesFile  UTF-8 file, one unique English name per line (deduped, capped here).
.PARAMETER Out        Destination TSV path.
#>
param(
    [Parameter(Mandatory = $true)] [string] $League,
    [Parameter(Mandatory = $true)] [string] $AuthFile,
    [Parameter(Mandatory = $true)] [string] $NamesFile,
    [Parameter(Mandatory = $true)] [string] $Out
)

$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
[System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::InvariantCulture

# ── Tunables (conservative on purpose) ──────────────────────────────────────────
$MaxNames     = 6      # uniques priced per invocation (2 API calls each)
$MaxIds       = 10     # listings fetched per unique (trade fetch hard-caps at 10)
$MinIntervalS = 3.5    # minimum seconds between ANY two API calls
$RobustCount  = 8      # take the median of the cheapest N listings as the price

function Normalize([string]$s) {
    if (-not $s) { return '' }
    return ($s.ToLowerInvariant() -replace '[^a-z0-9]', '')
}
function Clean([string]$s) {
    if (-not $s) { return '' }
    return ($s -replace "[`t`r`n]", ' ').Trim()
}

# ── Read auth (secrets) — never echoed anywhere ─────────────────────────────────
$sessId = ''; $cfClear = ''; $userAgent = ''
if (Test-Path -LiteralPath $AuthFile) {
    foreach ($line in [System.IO.File]::ReadAllLines($AuthFile)) {
        if (-not $line -or $line.StartsWith('#')) { continue }
        $eq = $line.IndexOf('=')
        if ($eq -lt 1) { continue }
        $k = $line.Substring(0, $eq).Trim().ToUpperInvariant()
        $v = $line.Substring($eq + 1).Trim()
        switch ($k) {
            'POESESSID'    { $sessId = $v }
            'CF_CLEARANCE' { $cfClear = $v }
            'USER_AGENT'   { $userAgent = $v }
        }
    }
}
if (-not $userAgent) { $userAgent = 'PoEformance/1.0 (+https://github.com/imm0r/poeformance)' }

$epoch = [int64][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
function Write-Out([string]$status, [string[]]$errors, $rows) {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("#meta`t$epoch`t$status`t" + (Clean ($errors -join '; ')) + "`n")
    if ($rows) {
        foreach ($r in $rows) {
            [void]$sb.Append("P`t$($r.norm)`t$($r.price)`t$($r.count)`t$($r.name)`n")
        }
    }
    [System.IO.File]::WriteAllText($Out, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
}

if (-not $sessId -or $sessId.Length -lt 8) {
    Write-Out 'error' @('no POESESSID in auth file') $null
    exit 0
}

# ── Currency → Exalted rates (poe.ninja public exchange; works on Standard) ──────
$rate = @{ 'exalted' = 1.0 }
$leagueParam = ([uri]::EscapeDataString($League.Trim())) -replace '%20', '+'
try {
    $url = "https://poe.ninja/poe2/api/economy/exchange/current/overview?league=$leagueParam&type=Currency"
    $resp = Invoke-RestMethod -Uri $url -Headers @{ 'User-Agent' = 'PoEformance-LootTracker/1.0' } -TimeoutSec 30
    $divToEx = 0.0
    if ($resp.core -and $resp.core.rates -and $resp.core.rates.exalted) { $divToEx = [double]$resp.core.rates.exalted }
    if ($divToEx -gt 0) { $rate['divine'] = $divToEx }
    # Map a few common currencies by their poe.ninja display name -> exalted.
    if ($resp.items -and $resp.lines) {
        $nameById = @{}
        foreach ($it in $resp.items) { if ($it.id -and $it.name) { $nameById[$it.id] = $it.name } }
        foreach ($ln in $resp.lines) {
            if (-not $ln.id -or -not $ln.primaryValue) { continue }
            $nm = if ($nameById.ContainsKey($ln.id)) { $nameById[$ln.id] } else { '' }
            $ex = [double]$ln.primaryValue * $divToEx
            switch -regex ($nm) {
                'Chaos Orb'        { if ($ex -gt 0) { $rate['chaos'] = $ex } }
                'Regal Orb'        { if ($ex -gt 0) { $rate['regal'] = $ex } }
                'Vaal Orb'         { if ($ex -gt 0) { $rate['vaal']  = $ex } }
                'Orb of Annulment' { if ($ex -gt 0) { $rate['annul'] = $ex } }
            }
        }
    }
} catch {
    # Non-fatal: we can still price exalted/divine listings if divine is known later.
}

# ── Read the unique-name queue ──────────────────────────────────────────────────
$names = @()
if (Test-Path -LiteralPath $NamesFile) {
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($line in [System.IO.File]::ReadAllLines($NamesFile)) {
        $n = Clean $line
        if (-not $n) { continue }
        $nk = Normalize $n
        if (-not $nk) { continue }
        if ($seen.Add($nk)) { $names += $n }
        if ($names.Count -ge $MaxNames) { break }
    }
}
if ($names.Count -eq 0) {
    Write-Out 'ready' @() @()
    exit 0
}

# ── Rate-limited HTTP helpers ───────────────────────────────────────────────────
$script:lastCall = [DateTime]::MinValue
function Wait-RateLimit {
    $dt = ([DateTime]::UtcNow - $script:lastCall).TotalSeconds
    if ($dt -lt $MinIntervalS) { Start-Sleep -Milliseconds ([int](($MinIntervalS - $dt) * 1000)) }
    $script:lastCall = [DateTime]::UtcNow
}
$cookie = "POESESSID=$sessId"
if ($cfClear) { $cookie += "; cf_clearance=$cfClear" }
$commonHeaders = @{ 'User-Agent' = $userAgent; 'Accept' = 'application/json'; 'Cookie' = $cookie }

$errors = @()
$rows = @()
$blocked = $false

function Invoke-Trade([string]$method, [string]$url, [string]$body) {
    Wait-RateLimit
    $hdr = $commonHeaders.Clone()
    try {
        if ($method -eq 'POST') {
            $hdr['Content-Type'] = 'application/json'
            return Invoke-WebRequest -Uri $url -Method Post -Headers $hdr -Body $body -TimeoutSec 30 -UseBasicParsing
        }
        return Invoke-WebRequest -Uri $url -Method Get -Headers $hdr -TimeoutSec 30 -UseBasicParsing
    } catch {
        $resp = $_.Exception.Response
        $code = 0
        try { if ($resp) { $code = [int]$resp.StatusCode } } catch {}
        if ($code -eq 429) {
            $retry = 0
            try { $retry = [int]$resp.Headers['Retry-After'] } catch {}
            if ($retry -le 0) { $retry = 60 }
            Start-Sleep -Seconds ([Math]::Min($retry, 90))
            throw [System.Exception]::new('429')
        }
        throw [System.Exception]::new("http$code")
    }
}

foreach ($name in $names) {
    if ($blocked) { break }
    $nk = Normalize $name
    try {
        $searchUrl = "https://www.pathofexile.com/api/trade2/search/poe2/$leagueParam"
        $query = @{ query = @{ status = @{ option = 'online' }; name = $name }; sort = @{ price = 'asc' } } | ConvertTo-Json -Depth 6 -Compress
        $sResp = Invoke-Trade 'POST' $searchUrl $query
        $sData = $sResp.Content | ConvertFrom-Json
        $qid = $sData.id
        $ids = @($sData.result)
        if (-not $qid -or $ids.Count -eq 0) {
            $rows += [pscustomobject]@{ norm = $nk; price = ''; count = 0; name = $name }   # negative cache
            continue
        }
        $take = $ids[0..([Math]::Min($MaxIds, $ids.Count) - 1)] -join ','
        $fetchUrl = "https://www.pathofexile.com/api/trade2/fetch/$take`?query=$qid&realm=poe2"
        $fResp = Invoke-Trade 'GET' $fetchUrl $null
        $fData = $fResp.Content | ConvertFrom-Json

        $vals = @()
        foreach ($r in @($fData.result)) {
            $p = $r.listing.price
            if (-not $p -or -not $p.amount -or -not $p.currency) { continue }
            $cur = ([string]$p.currency).ToLowerInvariant()
            if (-not $rate.ContainsKey($cur)) { continue }   # unknown currency -> skip (don't misvalue)
            $ex = [double]$p.amount * [double]$rate[$cur]
            if ($ex -gt 0) { $vals += $ex }
        }
        if ($vals.Count -eq 0) {
            $rows += [pscustomobject]@{ norm = $nk; price = ''; count = 0; name = $name }
            continue
        }
        $sorted = $vals | Sort-Object
        $n = [Math]::Min($RobustCount, $sorted.Count)
        $slice = $sorted[0..($n - 1)]
        $median = $slice[[int]([Math]::Floor(($n - 1) / 2))]
        $rows += [pscustomobject]@{ norm = $nk; price = [Math]::Round([double]$median, 3); count = $n; name = $name }
    } catch {
        $msg = $_.Exception.Message
        if ($msg -eq 'http403') {
            # 403 on the trade API is the Cloudflare/auth wall — stop and report.
            $blocked = $true
            $errors += "${name}: blocked (403 — refresh cf_clearance + User-Agent, or POESESSID expired)"
        } elseif ($msg -eq 'http401') {
            $blocked = $true
            $errors += "${name}: unauthorized (401 — POESESSID invalid/expired)"
        } else {
            $errors += "${name}: $msg"
        }
    }
}

$status = if ($blocked) { 'blocked' } elseif ($errors.Count -gt 0 -and $rows.Count -eq 0) { 'error' } else { 'ready' }
Write-Out $status $errors $rows
exit 0
