<#
.SYNOPSIS
  codex-switch - keep several API endpoints (URL + key) and switch the ChatGPT/Codex
  desktop app between them and your normal ChatGPT login.

.DESCRIPTION
  Profiles live in  %USERPROFILE%\.codex\codex-switch\profiles.json
  API keys are encrypted with Windows DPAPI (only your Windows account can decrypt them).

  "use <profile>" edits %USERPROFILE%\.codex\config.toml:
    - saves your original top-level model / model_provider / model_reasoning_effort / service_tier
    - sets model_provider = "codexswitch" and model = <profile model>
    - writes a [model_providers.codexswitch] table pointing at the profile's base URL
    - puts the key in the user environment variable CODEX_SWITCH_API_KEY
  "off" restores the saved values, removes the table and the env var.
  Your ChatGPT login (auth.json) is never touched. Every write makes a timestamped backup.

.EXAMPLE
  .\codex-switch.ps1                      # interactive menu
  .\codex-switch.ps1 add work -BaseUrl https://my-gateway.example/v1 -Model gpt-5.5
  .\codex-switch.ps1 use work -Restart
  .\codex-switch.ps1 off -Restart
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('menu', 'add', 'list', 'remove', 'use', 'off', 'status', 'test', 'models', 'refresh', 'purge', 'help')]
    [string]$Command = 'menu',
    [Parameter(Position = 1)][string]$Name,
    [string]$BaseUrl,
    [string]$Model,
    [string]$Effort,
    [string]$Key,          # optional; if omitted you are prompted (input hidden)
    [switch]$KeepKey,      # add: keep the stored key of an existing profile without prompting
    [switch]$Yes,          # purge: skip the confirmation prompt
    [switch]$InlineKey,    # use: write the key into config.toml instead of an env var
    [switch]$NoCatalog,    # use: don't replace the model picker list with the gateway's models
    [switch]$Restart       # use/off: quit and relaunch the desktop app
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$script:EffortGiven = $PSBoundParameters.ContainsKey('Effort')

$CodexHome    = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
$ConfigPath   = Join-Path $CodexHome 'config.toml'
$StoreDir     = Join-Path $CodexHome 'codex-switch'
$ProfilesPath = Join-Path $StoreDir 'profiles.json'
$StatePath    = Join-Path $StoreDir 'state.json'
$BackupDir    = Join-Path $StoreDir 'backups'
$ProviderId   = 'codexswitch'
$EnvVar       = 'CODEX_SWITCH_API_KEY'
$Marker       = '# managed by codex-switch (overwritten on every switch)'
# Top-level keys we take over while a profile is active and restore on "off".
$ManagedKeys  = @('model', 'model_provider', 'model_reasoning_effort', 'service_tier', 'model_catalog_json')
$CatalogPath  = Join-Path $StoreDir 'model-catalog.json'
$TemplatePath = Join-Path $StoreDir 'catalog-template.json'
$CachePath    = Join-Path $CodexHome 'models_cache.json'
$Utf8NoBom    = New-Object System.Text.UTF8Encoding($false)

function Ensure-Store { foreach ($d in $StoreDir, $BackupDir) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d | Out-Null } } }

# ---------------------------------------------------------------- profiles
function Get-Profiles {
    if (-not (Test-Path $ProfilesPath)) { return @() }
    $raw = [IO.File]::ReadAllText($ProfilesPath, [Text.Encoding]::UTF8)
    if (-not $raw.Trim()) { return @() }
    $data = ConvertFrom-Json $raw   # PS 5.1 returns the whole array as one object; unroll it
    return @($data | ForEach-Object { $_ })
}
function Save-Profiles($list) {
    Ensure-Store
    $json = ConvertTo-Json -InputObject @($list) -Depth 4
    [IO.File]::WriteAllText($ProfilesPath, $json, $Utf8NoBom)
}
function Find-Profile([string]$n) {
    $p = Get-Profiles | Where-Object { $_.name -eq $n } | Select-Object -First 1
    if (-not $p) { throw "No profile named '$n'. Run 'list' to see profiles." }
    return $p
}
function Unprotect-Key([string]$enc) {
    $ss = ConvertTo-SecureString $enc
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}
function Mask([string]$k) { if ($k.Length -le 8) { return '****' } return $k.Substring(0, 4) + '...' + $k.Substring($k.Length - 4) }

# ---------------------------------------------------------------- config.toml editing
function Read-ConfigLines {
    if (-not (Test-Path $ConfigPath)) { return , (New-Object System.Collections.Generic.List[string]) }
    $text = [IO.File]::ReadAllText($ConfigPath, [Text.Encoding]::UTF8)
    $script:NewLine = if ($text -match "`r`n") { "`r`n" } else { "`n" }
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($l in ($text -split "\r?\n")) { $list.Add($l) }
    # the final newline produces one empty element; drop exactly that one
    if ($list.Count -gt 0 -and $list[$list.Count - 1] -eq '') { $list.RemoveAt($list.Count - 1) }
    return , $list
}
$script:NewLine = "`r`n"
$DisabledPrefix = '#codex-switch# '
function Disable-TopLevel($lines, [string]$k) {
    # comment the key out in place so "off" can restore it at the same position
    $end = Get-FirstTableIndex $lines
    for ($i = 0; $i -lt $end; $i++) {
        if ($lines[$i] -match ('^\s*' + [regex]::Escape($k) + '\s*=')) { $lines[$i] = $DisabledPrefix + $lines[$i] }
    }
}
function Enable-Disabled($lines) {
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i].StartsWith($DisabledPrefix)) { $lines[$i] = $lines[$i].Substring($DisabledPrefix.Length) }
    }
}
function Write-ConfigLines($lines) {
    Ensure-Store
    if (Test-Path $ConfigPath) {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
        Copy-Item $ConfigPath (Join-Path $BackupDir "config.toml.$stamp.bak") -Force
        # keep the 20 newest backups
        Get-ChildItem $BackupDir -Filter 'config.toml.*.bak' | Sort-Object Name -Descending | Select-Object -Skip 20 | Remove-Item -Force
    } elseif (-not (Test-Path $CodexHome)) { New-Item -ItemType Directory -Path $CodexHome | Out-Null }
    $text = ($lines -join $script:NewLine) + $script:NewLine
    [IO.File]::WriteAllText($ConfigPath, $text, $Utf8NoBom)
}
function Get-FirstTableIndex($lines) {
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^\s*\[') { return $i } }
    return $lines.Count
}
function Get-TopLevel($lines, [string]$k) {
    $end = Get-FirstTableIndex $lines
    for ($i = 0; $i -lt $end; $i++) {
        if ($lines[$i] -match ('^\s*' + [regex]::Escape($k) + '\s*=\s*(.*?)\s*$')) { return $Matches[1] }
    }
    return $null
}
function Set-TopLevel($lines, [string]$k, $rawValue) {
    # Replace the first definition of $k above the first [table] in place; drop any duplicates.
    $end = Get-FirstTableIndex $lines
    $first = -1
    for ($i = $end - 1; $i -ge 0; $i--) {
        if ($lines[$i] -match ('^\s*' + [regex]::Escape($k) + '\s*=')) {
            if ($first -ge 0) { $lines.RemoveAt($first) }
            $first = $i
        }
    }
    if ($first -ge 0) {
        if ($null -ne $rawValue) { $lines[$first] = "$k = $rawValue" } else { $lines.RemoveAt($first) }
        return
    }
    if ($null -ne $rawValue) {
        $end = Get-FirstTableIndex $lines
        # insert after the last non-blank top-level line, so we stay above the first table
        $at = $end
        while ($at -gt 0 -and $lines[$at - 1].Trim() -eq '') { $at-- }
        $lines.Insert($at, "$k = $rawValue")
    }
}
function Remove-ProviderTable($lines) {
    $hdr = '^\s*\[\s*model_providers\.' + $ProviderId + '\s*\]\s*$'
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match $hdr) {
            $j = $i + 1
            while ($j -lt $lines.Count -and $lines[$j] -notmatch '^\s*\[') { $j++ }
            $start = $i
            if ($start -gt 0 -and $lines[$start - 1] -eq $Marker) {
                $start--
                # "use" always writes exactly one blank separator line before the marker
                if ($start -gt 0 -and $lines[$start - 1] -eq '') { $start-- }
            }
            $lines.RemoveRange($start, $j - $start)
            return
        }
    }
}
function ConvertTo-TomlString([string]$s) { return '"' + ($s -replace '\\', '\\' -replace '"', '\"') + '"' }

# ---------------------------------------------------------------- state
function Get-State {
    if (-not (Test-Path $StatePath)) { return $null }
    return ([IO.File]::ReadAllText($StatePath, [Text.Encoding]::UTF8) | ConvertFrom-Json)
}
function Get-Orig($st, [string]$k) { if ($st.original.PSObject.Properties[$k]) { return $st.original.$k } return $null }
function Save-State($obj) { Ensure-Store; [IO.File]::WriteAllText($StatePath, (ConvertTo-Json $obj -Depth 4), $Utf8NoBom) }

# ---------------------------------------------------------------- desktop app
function Get-AppProcesses {
    Get-Process -ErrorAction SilentlyContinue | Where-Object {
        try { $_.Path -and $_.Path -like '*\WindowsApps\OpenAI.Codex_*' } catch { $false }
    }
}
function Restart-App {
    $procs = @(Get-AppProcesses)
    if ($procs.Count) {
        Write-Host "Closing the desktop app ($($procs.Count) processes)..."
        $procs | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    }
    $app = Get-StartApps | Where-Object { $_.AppID -like 'OpenAI.Codex_*' } | Select-Object -First 1
    if (-not $app) { Write-Warning 'Could not find the ChatGPT/Codex desktop app in the Start menu. Start it yourself.'; return }
    Start-Process "shell:AppsFolder\$($app.AppID)"
    Write-Host "Relaunched $($app.Name)."
}
function Finish-Switch {
    if ($Restart) { Restart-App }
    elseif (@(Get-AppProcesses).Count) { Write-Host 'The desktop app is running: fully quit it (tray icon > Quit) and reopen it, or rerun with -Restart.' -ForegroundColor Yellow }
    else { Write-Host 'Open the desktop app to use it.' }
}

# ---------------------------------------------------------------- commands
function Cmd-Add {
    $n = $Name; if (-not $n) { $n = Read-Host 'Profile name' }
    if ($n -notmatch '^[A-Za-z0-9._-]+$') { throw 'Profile name: letters, digits, . _ - only.' }
    $existing = Get-Profiles | Where-Object { $_.name -eq $n } | Select-Object -First 1
    $url = $BaseUrl; if (-not $url) { $url = Read-Host ('Base URL (e.g. https://host/v1)' + $(if ($existing) { " [$($existing.baseUrl)]" })) }
    if (-not $url -and $existing) { $url = $existing.baseUrl }
    $url = $url.Trim().TrimEnd('/')
    if ($url -notmatch '^https?://') { throw 'Base URL must start with http:// or https://' }
    if ($url -notmatch '/v\d+$') { Write-Warning "Base URL usually ends in /v1 (Codex calls <base>/responses)." }
    $m = $Model; if (-not $m) { $m = Read-Host ('Model id' + $(if ($existing) { " [$($existing.model)]" })) }
    if (-not $m -and $existing) { $m = $existing.model }
    if (-not $m) { throw 'Model id is required.' }
    if ($Key) { $enc = ConvertTo-SecureString $Key.Trim() -AsPlainText -Force | ConvertFrom-SecureString }
    elseif ($KeepKey -and $existing) { $enc = $existing.keyEnc }
    elseif ($KeepKey) { throw 'API key is required for a new profile.' }
    else {
        $prompt = 'API key (hidden)' + $(if ($existing) { ' - leave empty to keep current' })
        $ss = Read-Host $prompt -AsSecureString
        if ($ss.Length -eq 0) { if ($existing) { $enc = $existing.keyEnc } else { throw 'API key is required.' } }
        else { $enc = ConvertFrom-SecureString $ss }
    }
    $eff = if ($script:EffortGiven) { $Effort } elseif ($existing) { $existing.effort } else { '' }
    $entry = [pscustomobject]@{ name = $n; baseUrl = $url; model = $m; effort = $eff; keyEnc = $enc }
    $list = @(Get-Profiles | Where-Object { $_.name -ne $n }) + $entry
    Save-Profiles $list
    Write-Host "Saved profile '$n' -> $url ($m)." -ForegroundColor Green
    $st = Get-State
    if ($st -and $st.active -eq $n) { Write-Host "It is the active profile; run 'use $n' again to apply the changes." }
}

function Cmd-List {
    $list = @(Get-Profiles); $st = Get-State
    if (-not $list.Count) { Write-Host "No profiles yet. Add one with: add <name> -BaseUrl <url> -Model <id>"; return }
    $i = 1
    foreach ($p in $list) {
        $mark = if ($st -and $st.active -eq $p.name) { '*' } else { ' ' }
        $eff = if ($p.effort) { " effort=$($p.effort)" } else { '' }
        Write-Host ("{0} {1,2}. {2,-16} {3}  model={4}{5}" -f $mark, $i, $p.name, $p.baseUrl, $p.model, $eff)
        $i++
    }
}

function Cmd-Remove {
    $n = $Name; if (-not $n) { $n = Read-Host 'Profile to remove' }
    $null = Find-Profile $n
    $st = Get-State
    if ($st -and $st.active -eq $n) { throw "'$n' is active. Run 'off' (or 'use' another profile) first." }
    Save-Profiles @(Get-Profiles | Where-Object { $_.name -ne $n })
    Write-Host "Removed '$n'."
}

function Cmd-Use {
    $n = $Name; if (-not $n) { $n = Read-Host 'Profile to use' }
    $p = Find-Profile $n
    $plain = Unprotect-Key $p.keyEnc
    $model = if ($Model) { $Model } else { $p.model }

    $lines = Read-ConfigLines
    if ($null -ne (Get-TopLevel $lines 'profile')) { Write-Warning "config.toml has a top-level 'profile = ...' which may override these settings." }

    $st = Get-State
    if (-not $st) {
        # first switch away from ChatGPT mode: remember the original values
        $orig = [ordered]@{}
        foreach ($k in $ManagedKeys) { $orig[$k] = Get-TopLevel $lines $k }
        if ($orig['model_provider'] -and ($orig['model_provider'] -replace '"', '') -eq $ProviderId) { throw 'config.toml already points at codexswitch but no saved state was found. Fix model_provider by hand first.' }
        $st = [pscustomobject]@{ active = $null; original = [pscustomobject]$orig; since = (Get-Date).ToString('s') }
    }

    Set-TopLevel $lines 'model_provider' (ConvertTo-TomlString $ProviderId)
    Set-TopLevel $lines 'model' (ConvertTo-TomlString $model)
    Disable-TopLevel $lines 'service_tier'   # ChatGPT-only "fast" tier; most gateways reject it
    if ($p.effort) { Set-TopLevel $lines 'model_reasoning_effort' (ConvertTo-TomlString $p.effort) }
    else { Set-TopLevel $lines 'model_reasoning_effort' (Get-Orig $st 'model_reasoning_effort') }

    $cat = $null
    if (-not $NoCatalog) { $cat = Write-ModelCatalog $p $plain $model }
    if ($cat) { Set-TopLevel $lines 'model_catalog_json' (ConvertTo-TomlLiteral $cat) }
    else { Set-TopLevel $lines 'model_catalog_json' (Get-Orig $st 'model_catalog_json') }

    Remove-ProviderTable $lines
    $lines.Add('')
    $lines.Add($Marker)
    $lines.Add("[model_providers.$ProviderId]")
    $lines.Add('name = ' + (ConvertTo-TomlString "codex-switch ($n)"))
    $lines.Add('base_url = ' + (ConvertTo-TomlString $p.baseUrl))
    $lines.Add('wire_api = "responses"')
    $lines.Add('requires_openai_auth = false')
    if ($InlineKey) { $lines.Add('experimental_bearer_token = ' + (ConvertTo-TomlString $plain)) }
    else { $lines.Add("env_key = `"$EnvVar`"") }
    Write-ConfigLines $lines

    if ($InlineKey) { [Environment]::SetEnvironmentVariable($EnvVar, $null, 'User') }
    else {
        [Environment]::SetEnvironmentVariable($EnvVar, $plain, 'User')
        Set-Item "env:$EnvVar" $plain   # so a relaunch from this window sees it too
    }
    $st.active = $n
    Save-State $st
    Write-Host "Codex now uses '$n' -> $($p.baseUrl) ($model), key $(Mask $plain)$(if ($InlineKey) { ' [inline]' })." -ForegroundColor Green
    Finish-Switch
}

function Cmd-Off {
    $st = Get-State
    $lines = Read-ConfigLines
    if (-not $st) {
        Enable-Disabled $lines
        Remove-ProviderTable $lines
        if (((Get-TopLevel $lines 'model_provider') -replace '"', '') -eq $ProviderId) { Set-TopLevel $lines 'model_provider' $null }
        Write-ConfigLines $lines
        [Environment]::SetEnvironmentVariable($EnvVar, $null, 'User')
        Write-Host 'Already in ChatGPT mode (no saved state). Cleaned up any leftovers.'
        return
    }
    Enable-Disabled $lines
    foreach ($k in $ManagedKeys) {
        if ($k -eq 'service_tier' -and $null -ne (Get-TopLevel $lines $k)) { continue }   # already uncommented in place
        Set-TopLevel $lines $k (Get-Orig $st $k)
    }
    Remove-ProviderTable $lines
    Write-ConfigLines $lines
    [Environment]::SetEnvironmentVariable($EnvVar, $null, 'User')
    Remove-Item "env:$EnvVar" -ErrorAction SilentlyContinue
    Remove-Item $StatePath -Force
    if (Test-Path $CatalogPath) { Remove-Item $CatalogPath -Force }
    Write-Host "Back to your ChatGPT login (was '$($st.active)'). Original settings restored." -ForegroundColor Green
    Finish-Switch
}

function Cmd-Status {
    $st = Get-State; $lines = Read-ConfigLines
    if ($st) { Write-Host "Mode: API profile '$($st.active)' (since $($st.since))" -ForegroundColor Cyan }
    else { Write-Host 'Mode: ChatGPT login (default provider)' -ForegroundColor Cyan }
    foreach ($k in 'model_provider', 'model', 'model_reasoning_effort', 'service_tier') {
        $v = Get-TopLevel $lines $k; if ($null -eq $v) { $v = '(not set)' }
        Write-Host ("  {0,-24} {1}" -f $k, $v)
    }
    $envSet = [bool][Environment]::GetEnvironmentVariable($EnvVar, 'User')
    Write-Host ("  {0,-24} {1}" -f "$EnvVar env", $(if ($envSet) { 'set' } else { 'not set' }))
    Write-Host ("  {0,-24} {1}" -f 'desktop app', $(if (@(Get-AppProcesses).Count) { 'running' } else { 'not running' }))
    Write-Host "  config: $ConfigPath"
}

function Invoke-Probe($method, $url, $body, $plainKey) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    try {
        $req = @{ Uri = $url; Method = $method; Headers = @{ Authorization = "Bearer $plainKey" }; UseBasicParsing = $true; TimeoutSec = 120 }
        if ($body) { $req.Body = [Text.Encoding]::UTF8.GetBytes($body); $req.ContentType = 'application/json' }
        $r = Invoke-WebRequest @req
        return @{ code = [int]$r.StatusCode; body = $r.Content }
    } catch {
        $code = 0; $txt = $_.Exception.Message
        if ($_.Exception.Response) {
            $code = [int]$_.Exception.Response.StatusCode
            try { $txt = (New-Object IO.StreamReader($_.Exception.Response.GetResponseStream())).ReadToEnd() } catch {}
        }
        return @{ code = $code; body = $txt }
    }
}
function Get-GatewayModels([string]$url, [string]$plainKey) {
    $m = Invoke-Probe 'GET' "$($url.TrimEnd('/'))/models" $null $plainKey
    if ($m.code -ne 200) { throw "GET /models returned $($m.code): $($m.body)" }
    return @(($m.body | ConvertFrom-Json).data | Where-Object { $_.id })
}
function Get-ModelIds([string]$url, [string]$plainKey) { return @(Get-GatewayModels $url $plainKey | ForEach-Object { $_.id } | Sort-Object) }

# ---------------------------------------------------------------- model picker catalog
function Copy-Deep($o) { return ($o | ConvertTo-Json -Depth 30 -Compress | ConvertFrom-Json) }
function Get-CachedModels {
    # Codex's own downloaded catalog: the source of correctly-shaped model entries for this Codex version
    if (-not (Test-Path $CachePath)) { return @() }
    try { return @((ConvertFrom-Json ([IO.File]::ReadAllText($CachePath, [Text.Encoding]::UTF8))).models) } catch { return @() }
}
function Get-CatalogTemplate($cached) {
    $t = $cached | Where-Object { $_.visibility -eq 'list' } | Sort-Object priority | Select-Object -First 1
    if ($t) {
        Ensure-Store
        [IO.File]::WriteAllText($TemplatePath, ($t | ConvertTo-Json -Depth 30), $Utf8NoBom)   # keep for when the cache is gone
        return $t
    }
    if (Test-Path $TemplatePath) { return (ConvertFrom-Json ([IO.File]::ReadAllText($TemplatePath, [Text.Encoding]::UTF8))) }
    return $null
}
function Write-ModelCatalog($p, [string]$plainKey, [string]$defaultModel) {
    # Returns the catalog path, or $null if it could not be built (Codex then keeps its normal list).
    try { $gw = Get-GatewayModels $p.baseUrl $plainKey }
    catch { Write-Warning "Model list not loaded ($($_.Exception.Message)); the picker keeps Codex's default list."; return $null }
    if (-not $gw.Count) { Write-Warning 'The endpoint returned no models; the picker keeps Codex''s default list.'; return $null }
    $cached = Get-CachedModels
    $template = Get-CatalogTemplate $cached
    if (-not $template) { Write-Warning "No Codex model cache found to copy entries from (open Codex once with your ChatGPT login). The picker keeps Codex's default list."; return $null }

    # profile model first, then the rest alphabetically
    $ordered = @($gw | Where-Object { $_.id -eq $defaultModel }) + @($gw | Where-Object { $_.id -ne $defaultModel } | Sort-Object id)
    if (-not ($gw | Where-Object { $_.id -eq $defaultModel })) { $ordered = @([pscustomobject]@{ id = $defaultModel }) + $ordered }
    $entries = @(); $prio = 1
    foreach ($g in $ordered) {
        $same = $cached | Where-Object { $_.slug -eq $g.id } | Select-Object -First 1
        $e = if ($same) { Copy-Deep $same } else { Copy-Deep $template }
        $e.slug = [string]$g.id
        $dn = $null; if ($g.PSObject.Properties['display_name'] -and $g.display_name) { $dn = [string]$g.display_name }
        if (-not $same) { $e.display_name = $(if ($dn) { $dn } else { [string]$g.id }) }
        $e.description = "via $($p.name) ($($p.baseUrl))"
        $e.visibility = 'list'
        $e.priority = $prio++
        foreach ($f in 'upgrade', 'availability_nux') { if ($e.PSObject.Properties[$f]) { $e.$f = $null } }
        $entries += $e
    }
    Ensure-Store
    $json = ConvertTo-Json -InputObject ([pscustomobject]@{ models = $entries }) -Depth 30
    [IO.File]::WriteAllText($CatalogPath, $json, $Utf8NoBom)
    Write-Host "Model picker: $($entries.Count) models from $($p.name)."
    return $CatalogPath
}
function ConvertTo-TomlLiteral([string]$s) { if ($s -notmatch "'") { return "'" + $s + "'" } return ConvertTo-TomlString $s }
function Cmd-Models {
    # models <profile>  or  models -BaseUrl <url> -Key <key>
    if ($Name) { $p = Find-Profile $Name; $url = $p.baseUrl; $k = Unprotect-Key $p.keyEnc }
    else { $url = $BaseUrl; $k = $Key; if (-not $url -or -not $k) { throw 'Give a profile name, or -BaseUrl and -Key.' } }
    Get-ModelIds $url $k
}
function Get-CatalogSlugs {
    if (-not (Test-Path $CatalogPath)) { return @() }
    try { return @((ConvertFrom-Json ([IO.File]::ReadAllText($CatalogPath, [Text.Encoding]::UTF8))).models | ForEach-Object { $_.slug }) } catch { return @() }
}
function Cmd-Refresh {
    # Re-fetch the active API's model list and rebuild the picker catalog.
    $st = Get-State
    if (-not $st) { Write-Host 'No API is active; nothing to refresh.'; return }
    $p = Find-Profile $st.active
    $plain = Unprotect-Key $p.keyEnc
    $lines = Read-ConfigLines
    $cur = Get-TopLevel $lines 'model'
    $model = if ($cur) { $cur.Trim('"', "'") } else { $p.model }   # keep whatever is selected now
    $old = Get-CatalogSlugs
    $cat = Write-ModelCatalog $p $plain $model
    if (-not $cat) { return }
    $new = Get-CatalogSlugs
    $want = ConvertTo-TomlLiteral $cat
    if ((Get-TopLevel $lines 'model_catalog_json') -ne $want) { Set-TopLevel $lines 'model_catalog_json' $want; Write-ConfigLines $lines }
    $added = @($new | Where-Object { $old -notcontains $_ }); $gone = @($old | Where-Object { $new -notcontains $_ })
    if (-not $added.Count -and -not $gone.Count) { Write-Host "Model list unchanged ($($new.Count) models)."; return }
    if ($added.Count) { Write-Host ("  added:   " + ($added -join ', ')) -ForegroundColor Green }
    if ($gone.Count)  { Write-Host ("  removed: " + ($gone -join ', ')) -ForegroundColor Yellow }
    Finish-Switch
}
function Cmd-Purge {
    if (-not $Yes) {
        $a = Read-Host 'Switch back to ChatGPT and DELETE all saved profiles, keys and backups? Type YES'
        if ($a -cne 'YES') { Write-Host 'Cancelled.'; return }
    }
    Cmd-Off
    if (Test-Path $StoreDir) { Remove-Item $StoreDir -Recurse -Force }
    [Environment]::SetEnvironmentVariable($EnvVar, $null, 'User')
    Write-Host 'All custom APIs removed. Codex is on your ChatGPT login; nothing from codex-switch is left in .codex.' -ForegroundColor Green
}

function Cmd-Test {
    $n = $Name; if (-not $n) { $n = Read-Host 'Profile to test' }
    $p = Find-Profile $n
    $plain = Unprotect-Key $p.keyEnc
    $model = if ($Model) { $Model } else { $p.model }
    function Probe($method, $url, $body) { Invoke-Probe $method $url $body $plain }
    Write-Host "Testing '$n' ($($p.baseUrl), model $model)..."
    $m = Probe 'GET' "$($p.baseUrl)/models" $null
    $ok = $m.code -eq 200
    Write-Host ("  GET  /models     -> {0} {1}" -f $m.code, $(if ($ok) { 'OK' } else { 'failed (optional - Codex does not need it)' }))
    if ($ok) {
        try { $ids = @(($m.body | ConvertFrom-Json).data | ForEach-Object { $_.id }); Write-Host ("                      {0} models; '{1}' {2}" -f $ids.Count, $model, $(if ($ids -contains $model) { 'is listed' } else { 'NOT listed' })) } catch {}
    }
    $body = @{ model = $model; input = 'Reply with the single word OK.'; max_output_tokens = 32 } | ConvertTo-Json
    $r = Probe 'POST' "$($p.baseUrl)/responses" $body
    if ($r.code -eq 200) { Write-Host "  POST /responses  -> 200 OK  (Codex will work with this endpoint)" -ForegroundColor Green }
    else {
        $snippet = if ($r.body) { $r.body.Substring(0, [Math]::Min(300, $r.body.Length)) } else { '' }
        Write-Host "  POST /responses  -> $($r.code) FAILED" -ForegroundColor Red
        Write-Host "      $snippet"
        Write-Host '      Codex needs the Responses API (/responses). A /chat/completions-only gateway will not work.'
    }
}

function Cmd-Help { Get-Help $PSCommandPath -Detailed | Out-String | Write-Host
    Write-Host @"
Commands:
  add <name> [-BaseUrl url] [-Model id] [-Effort low|medium|high] [-Key k]   add or update a profile (key prompted if omitted)
  list                                   show profiles (* = active)
  use <name> [-Model id] [-InlineKey] [-Restart]   switch Codex to a profile
  off [-Restart]                         switch back to your ChatGPT login
  status                                 show the current mode
  test <name> [-Model id]                check the endpoint answers /responses
  remove <name>                          delete a profile
  models <name>                          list the model ids the endpoint offers
  refresh [-Restart]                     re-fetch the active API's models into the desktop model picker
  purge [-Yes] [-Restart]                switch back to ChatGPT and delete ALL profiles, keys and backups
"@
}

function Cmd-Menu {
    while ($true) {
        Write-Host ''
        Cmd-Status
        Write-Host ''
        Cmd-List
        Write-Host ''
        $c = Read-Host '[number] use profile  [o] off/ChatGPT  [a] add/edit  [t] test  [r] remove  [q] quit'
        try {
            switch -Regex ($c) {
                '^\d+$' {
                    $list = @(Get-Profiles); $idx = [int]$c - 1
                    if ($idx -lt 0 -or $idx -ge $list.Count) { Write-Host 'No such number.'; break }
                    $script:Name = $list[$idx].name
                    $script:Restart = ((Read-Host 'Restart the desktop app now? [Y/n]') -notmatch '^[nN]')
                    Cmd-Use; break
                }
                '^[oO]$' { $script:Restart = ((Read-Host 'Restart the desktop app now? [Y/n]') -notmatch '^[nN]'); Cmd-Off; break }
                '^[aA]$' { $script:Name = $null; Cmd-Add; break }
                '^[tT]$' { $script:Name = Read-Host 'Profile to test'; Cmd-Test; break }
                '^[rR]$' { $script:Name = Read-Host 'Profile to remove'; Cmd-Remove; break }
                '^[qQ]$' { return }
                default { Write-Host 'Unknown choice.' }
            }
        } catch { Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red }
    }
}

switch ($Command) {
    'menu'   { Cmd-Menu }
    'add'    { Cmd-Add }
    'list'   { Cmd-List }
    'remove' { Cmd-Remove }
    'use'    { Cmd-Use }
    'off'    { Cmd-Off }
    'status' { Cmd-Status }
    'test'   { Cmd-Test }
    'models' { Cmd-Models }
    'refresh' { Cmd-Refresh }
    'purge'  { Cmd-Purge }
    'help'   { Cmd-Help }
}
