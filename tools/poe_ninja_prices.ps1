<#
.SYNOPSIS
  Fetches PoE2 prices from poe.ninja and reduces them to a compact TSV the
  PoEformance LootTracker (ahk\LootPricing.ahk) loads cheaply.

.DESCRIPTION
  A faithful port of the GameHelper2 LootTracker plugin's PriceCache.cs. Runs as a
  detached child process so the AHK radar hot path is never blocked by the network
  call or the multi-MB JSON parse. poe.ninja's PoE2 economy API returns, per overview
  type:
    core.rates.exalted   -> 1 Divine in Exalted Orb units (the conversion rate)
    items[{id,name,image}]   id -> display-name / art lookup (exchange family)
    lines[{id,primaryValue}] id -> price in Divine (exchange family)
  Item/stash overviews carry name/baseType/icon/primaryValue/variant inline.

  Output TSV (UTF-8, tab-separated):
    #meta  <divToEx>  <epochSeconds>  <errorsOrEmpty>
    A      <normArtKey>  <priceOrEmpty>  <nameOrEmpty>
    N      <normName>    <price>

.PARAMETER League
  poe.ninja PoE2 league slug (spaces become '+').

.PARAMETER Out
  Destination TSV path (written atomically only on at least partial success).
#>
param(
    [Parameter(Mandatory = $true)] [string] $League,
    [Parameter(Mandatory = $true)] [string] $Out,
    # Liquidity gates — poe.ninja's RAW API includes illiquid / price-fixed
    # lines its own website hides (e.g. a unique with 3 troll listings at
    # 6257 div). Exchange lines below MinVolume (divine traded) and item
    # lines below MinListings are skipped; both fail OPEN when the API
    # omits the field, so a schema change can never blank the whole TSV.
    [double] $MinVolume = 1.0,
    [int] $MinListings = 5
)

$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
# Force invariant number formatting so decimals are always written with '.' (a German
# locale would otherwise emit "1,5" and break the AHK-side numeric parse).
[System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::InvariantCulture

# exchange/current/overview — the fungible/stackable economy (currency-like).
$ExchangeTypes = @(
    'Currency', 'Fragments', 'Abyss', 'UncutGems', 'LineageSupportGems', 'Essences',
    'SoulCores', 'Idols', 'Runes', 'Ritual', 'Expedition', 'Delirium', 'Breach', 'Verisium'
)
# stash/current/item/overview — individually-listed gear (uniques, tablets).
# NOTE: a wrong/unknown type slug just lands in the per-type catch below (recorded in
# the #meta errors field) and is skipped — so it's safe to list candidates. The big
# unique classes (weapons/armours/accessories/flasks) are what make dropped uniques
# like rings/amulets/staves price; jewels/charms/tablets were the only ones before.
$ItemTypes = @(
    'UniqueWeapons', 'UniqueArmours', 'UniqueAccessories', 'UniqueFlasks',
    'UniqueJewels', 'UniqueCharms', 'UniqueRelics', 'UniqueTablets', 'PrecursorTablets'
)

function Normalize([string]$s) {
    if (-not $s) { return '' }
    return ($s.ToLowerInvariant() -replace '[^a-z0-9]', '')
}

# poe.ninja image URL -> the item's art asset basename (its language-independent id).
function Get-ArtId([string]$imageUrl) {
    if (-not $imageUrl) { return '' }
    $s = $imageUrl
    $q = $s.IndexOf('?'); if ($q -ge 0) { $s = $s.Substring(0, $q) }
    $slash = $s.LastIndexOf('/'); if ($slash -ge 0) { $s = $s.Substring($slash + 1) }
    $dot = $s.LastIndexOf('.'); if ($dot -gt 0) { $s = $s.Substring(0, $dot) }
    return $s
}

# base=1, greater-=2, perfect-=3 (only meaningful for shared-icon tier families).
function Get-Grade([string]$id) {
    if (-not $id) { return 1 }
    if ($id.StartsWith('perfect-')) { return 3 }
    if ($id.StartsWith('greater-')) { return 2 }
    return 1
}

# trailing "-<n>" level (e.g. "thaumaturgic-flux-9" -> 9), or -1 if none.
function Get-TrailingLevel([string]$id) {
    if (-not $id) { return -1 }
    if ($id -match '-(\d+)$') { return [int]$Matches[1] }
    return -1
}

function Clean([string]$s) {
    if (-not $s) { return '' }
    return ($s -replace "[`t`r`n]", ' ').Trim()
}

$artPrice = @{}   # normalized art key -> unit price in Exalted
$artName  = @{}   # normalized art key -> poe.ninja English name
$namePrice = @{}  # normalized display name -> unit price in Exalted
$divToEx = 0.0
$errors = @()
$skippedThin = 0  # lines dropped by the liquidity gates (reported in #meta)

$leagueParam = ([uri]::EscapeDataString($League.Trim())) -replace '%20', '+'
$headers = @{ 'User-Agent' = 'PoEformance-LootTracker/1.0' }

# ── Exchange family ────────────────────────────────────────────────────────────
foreach ($type in $ExchangeTypes) {
    try {
        $url = "https://poe.ninja/poe2/api/economy/exchange/current/overview?league=$leagueParam&type=$type"
        $resp = Invoke-RestMethod -Uri $url -Headers $headers -TimeoutSec 30
        $localRate = 0.0
        if ($resp.core -and $resp.core.rates -and $resp.core.rates.exalted) { $localRate = [double]$resp.core.rates.exalted }
        if ($localRate -gt 0) { $divToEx = $localRate }

        $nameById = @{}; $bareArtById = @{}; $gradeById = @{}; $gradesPerArt = @{}; $levelKeyById = @{}
        if ($resp.items) {
            foreach ($it in $resp.items) {
                $id = $it.id; if (-not $id) { continue }
                if ($it.name) { $nameById[$id] = $it.name }
                $art = Get-ArtId $it.image
                if (-not $art) { continue }
                $grade = Get-Grade $id
                $bareArtById[$id] = $art
                $gradeById[$id] = $grade
                if (-not $gradesPerArt.ContainsKey($art)) { $gradesPerArt[$art] = New-Object 'System.Collections.Generic.HashSet[int]' }
                [void]$gradesPerArt[$art].Add($grade)
                $lvl = Get-TrailingLevel $id
                if ($lvl -ge 0) { $levelKeyById[$id] = "$art$lvl" }
            }
        }

        $artById = @{}
        foreach ($id in $bareArtById.Keys) {
            $art = $bareArtById[$id]; $grade = $gradeById[$id]
            $shared = $gradesPerArt[$art].Count -gt 1
            $artKey = if ($shared -and $grade -gt 1) { "$art$grade" } else { $art }
            $artById[$id] = $artKey
            if ($nameById.ContainsKey($id)) {
                $nk = Normalize $artKey
                if ($nk) { $artName[$nk] = $nameById[$id] }
                if ($levelKeyById.ContainsKey($id)) {
                    $lnk = Normalize $levelKeyById[$id]
                    if ($lnk) { $artName[$lnk] = $nameById[$id] }
                }
            }
        }

        if ($resp.lines) {
            foreach ($ln in $resp.lines) {
                $id = $ln.id
                $primary = 0.0; if ($ln.primaryValue) { $primary = [double]$ln.primaryValue }
                if (-not $id -or $primary -le 0) { continue }
                # Liquidity gate: volumePrimaryValue = divine traded through the
                # in-game exchange. Thin lines are ask-fantasy, not prices.
                if ($ln.PSObject.Properties['volumePrimaryValue']) {
                    if ([double]$ln.volumePrimaryValue -lt $MinVolume) { $skippedThin++; continue }
                }
                $price = $primary * $localRate
                if ($nameById.ContainsKey($id)) {
                    $k = Normalize $nameById[$id]; if ($k) { $namePrice[$k] = $price }
                }
                if ($artById.ContainsKey($id)) {
                    $k = Normalize $artById[$id]; if ($k) { $artPrice[$k] = $price }
                }
                if ($levelKeyById.ContainsKey($id)) {
                    $k = Normalize $levelKeyById[$id]; if ($k) { $artPrice[$k] = $price }
                }
            }
        }
    }
    catch {
        $errors += "${type}: $($_.Exception.Message)"
    }
}

# ── Item/stash family (uniques & tablets) ──────────────────────────────────────
foreach ($type in $ItemTypes) {
    try {
        $url = "https://poe.ninja/poe2/api/economy/stash/current/item/overview?league=$leagueParam&type=$type"
        $resp = Invoke-RestMethod -Uri $url -Headers $headers -TimeoutSec 30
        $localRate = 0.0
        if ($resp.core -and $resp.core.rates -and $resp.core.rates.exalted) { $localRate = [double]$resp.core.rates.exalted }
        if ($localRate -gt 0) { $divToEx = $localRate }
        $rate = if ($localRate -gt 0) { $localRate } else { $divToEx }

        if ($resp.lines) {
            foreach ($ln in $resp.lines) {
                $name = $ln.name
                $primary = 0.0; if ($ln.primaryValue) { $primary = [double]$ln.primaryValue }
                if (-not $name -or $primary -le 0 -or $rate -le 0) { continue }
                # Liquidity gate: a handful of listings is a price-fix magnet
                # (seen live: a junk unique with listingCount=3 at 6257 div).
                if ($ln.PSObject.Properties['listingCount']) {
                    if ([int]$ln.listingCount -lt $MinListings) { $skippedThin++; continue }
                }
                $price = $primary * $rate
                $variant = $ln.variant

                $nk = Normalize $name
                if ($nk -and ((-not $namePrice.ContainsKey($nk)) -or ($price -gt $namePrice[$nk]))) { $namePrice[$nk] = $price }

                $art = Get-ArtId $ln.icon
                if ($art) {
                    $ak = Normalize $art
                    if ($ak -and ((-not $artPrice.ContainsKey($ak)) -or ($price -gt $artPrice[$ak]))) { $artPrice[$ak] = $price; $artName[$ak] = $name }
                    if ($variant) {
                        $vk = Normalize "$art$variant"
                        if ($vk -and ((-not $artPrice.ContainsKey($vk)) -or ($price -gt $artPrice[$vk]))) { $artPrice[$vk] = $price; $artName[$vk] = $name }
                    }
                }
            }
        }
    }
    catch {
        $errors += "${type}: $($_.Exception.Message)"
    }
}

# Ensure the reference currencies themselves are queryable.
if ($divToEx -gt 0) {
    $namePrice[(Normalize 'Exalted Orb')] = 1.0
    $namePrice[(Normalize 'Divine Orb')] = $divToEx
}

if ($namePrice.Count -eq 0 -and $artPrice.Count -eq 0) {
    Write-Error ("no prices fetched: " + ($errors -join '; '))
    exit 1
}

# ── Emit TSV ────────────────────────────────────────────────────────────────────
$epoch = [int64][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
if ($skippedThin -gt 0) { $errors += "thin-market lines skipped: $skippedThin" }
$errText = Clean ($errors -join '; ')
$sb = New-Object System.Text.StringBuilder
[void]$sb.Append("#meta`t$divToEx`t$epoch`t$errText`n")

$artKeys = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($k in $artPrice.Keys) { [void]$artKeys.Add($k) }
foreach ($k in $artName.Keys)  { [void]$artKeys.Add($k) }
foreach ($k in $artKeys) {
    $p = if ($artPrice.ContainsKey($k)) { $artPrice[$k] } else { '' }
    $n = if ($artName.ContainsKey($k))  { Clean $artName[$k] } else { '' }
    [void]$sb.Append("A`t$k`t$p`t$n`n")
}
foreach ($kv in $namePrice.GetEnumerator()) {
    [void]$sb.Append("N`t$($kv.Key)`t$($kv.Value)`n")
}

[System.IO.File]::WriteAllText($Out, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
exit 0
