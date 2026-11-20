# codex-switch GUI - add/edit/remove API profiles and switch the ChatGPT/Codex desktop app.
# All real work is done by codex-switch.ps1 next to this file.
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
$ErrorActionPreference = 'Stop'

$Cli          = Join-Path $PSScriptRoot 'codex-switch.ps1'
$CodexHome    = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
$ProfilesPath = Join-Path $CodexHome 'codex-switch\profiles.json'
$StatePath    = Join-Path $CodexHome 'codex-switch\state.json'
$Font         = New-Object System.Drawing.Font('Segoe UI', 9.5)

function Read-Json($path) {
    if (-not (Test-Path $path)) { return $null }
    $raw = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
    if (-not $raw.Trim()) { return $null }
    return (ConvertFrom-Json $raw)
}
function Get-Profiles { $d = Read-Json $ProfilesPath; if ($null -eq $d) { return @() }; return @($d | ForEach-Object { $_ }) }

function Invoke-Cli([object[]]$argList) {
    $form.Cursor = 'WaitCursor'; [System.Windows.Forms.Application]::DoEvents()
    try {
        $out = & $Cli @argList *>&1 | Out-String
        Add-Log $out.Trim()
        return $true
    } catch {
        Add-Log ("Error: " + $_.Exception.Message)
        return $false
    } finally { $form.Cursor = 'Default'; Refresh-View }
}
function Add-Log([string]$t) {
    if (-not $t) { return }
    $log.AppendText(('[' + (Get-Date -Format 'HH:mm:ss') + '] ' + ($t -replace "`r?`n", "`r`n") + "`r`n"))
}

# ------------------------------------------------------------------ main window
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Codex API Switch'
$form.Size = New-Object System.Drawing.Size(860, 640)
$form.MinimumSize = New-Object System.Drawing.Size(720, 460)
$form.StartPosition = 'CenterScreen'
$form.Font = $Font
$form.BackColor = [System.Drawing.Color]::White

$status = New-Object System.Windows.Forms.Label
$status.Location = '16,14'; $status.Size = '640,26'; $status.Anchor = 'Top,Left,Right'
$status.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($status)

$list = New-Object System.Windows.Forms.ListView
$list.Location = '16,48'; $list.Size = '640,350'; $list.Anchor = 'Top,Left,Right,Bottom'
$list.View = 'Details'; $list.FullRowSelect = $true; $list.MultiSelect = $false; $list.HideSelection = $false
[void]$list.Columns.Add('', 28)
[void]$list.Columns.Add('Name', 120)
[void]$list.Columns.Add('Base URL', 280)
[void]$list.Columns.Add('Model', 130)
[void]$list.Columns.Add('Effort', 70)
$form.Controls.Add($list)

$log = New-Object System.Windows.Forms.TextBox
$log.Location = '16,410'; $log.Size = '812,170'; $log.Anchor = 'Left,Right,Bottom'
$log.Multiline = $true; $log.ScrollBars = 'Vertical'; $log.ReadOnly = $true
$log.Font = New-Object System.Drawing.Font('Consolas', 9); $log.BackColor = [System.Drawing.Color]::FromArgb(248, 248, 246)
$form.Controls.Add($log)

$y = 48
function New-Btn([string]$text, [int]$gap = 6) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text; $b.Location = New-Object System.Drawing.Point(672, $script:y); $b.Size = '156,32'; $b.Anchor = 'Top,Right'
    $form.Controls.Add($b); $script:y += 32 + $gap
    return $b
}
$btnUse    = New-Btn 'Use selected API'
$btnOff    = New-Btn 'Back to ChatGPT' 18
$btnAdd    = New-Btn 'Add API...'
$btnEdit   = New-Btn 'Edit...'
$btnRemove = New-Btn 'Remove'
$btnTest   = New-Btn 'Test'
$btnRefresh = New-Btn 'Refresh models' 18
$btnPurge  = New-Btn 'Remove everything...'
$btnUse.Font = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Bold)
$btnPurge.ForeColor = [System.Drawing.Color]::FromArgb(170, 30, 30)

$chkRestart = New-Object System.Windows.Forms.CheckBox
$chkRestart.Text = 'Restart app on switch'; $chkRestart.Checked = $true
$chkRestart.Location = New-Object System.Drawing.Point(672, ($y + 4)); $chkRestart.Size = '170,24'; $chkRestart.Anchor = 'Top,Right'
$form.Controls.Add($chkRestart)

function Selected-Name { if ($list.SelectedItems.Count) { return $list.SelectedItems[0].SubItems[1].Text } return $null }

function Refresh-View {
    $keep = Selected-Name
    $st = Read-Json $StatePath
    $active = if ($st) { $st.active } else { $null }
    if ($active) { $status.Text = "Now using API: $active"; $status.ForeColor = [System.Drawing.Color]::FromArgb(20, 90, 160) }
    else { $status.Text = 'Now using: ChatGPT login (default)'; $status.ForeColor = [System.Drawing.Color]::FromArgb(30, 110, 50) }
    $list.BeginUpdate(); $list.Items.Clear()
    foreach ($p in Get-Profiles) {
        $it = New-Object System.Windows.Forms.ListViewItem($(if ($p.name -eq $active) { [string][char]0x25CF } else { '' }))
        [void]$it.SubItems.Add($p.name); [void]$it.SubItems.Add($p.baseUrl); [void]$it.SubItems.Add($p.model); [void]$it.SubItems.Add([string]$p.effort)
        if ($p.name -eq $active) { $it.Font = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Bold) }
        [void]$list.Items.Add($it)
        if ($p.name -eq $keep) { $it.Selected = $true }
    }
    $list.EndUpdate()
    $btnOff.Enabled = [bool]$active
    $btnRefresh.Enabled = [bool]$active
}

# ------------------------------------------------------------------ add / edit dialog
function Show-ProfileDialog($existing) {
    $d = New-Object System.Windows.Forms.Form
    $d.Text = $(if ($existing) { "Edit API - $($existing.name)" } else { 'Add API' })
    $d.Size = '520,330'; $d.StartPosition = 'CenterParent'; $d.FormBorderStyle = 'FixedDialog'
    $d.MaximizeBox = $false; $d.MinimizeBox = $false; $d.Font = $Font; $d.BackColor = [System.Drawing.Color]::White
    $script:row = 18
    function Add-Row([string]$label, $ctrl, [int]$w = 340) {
        $l = New-Object System.Windows.Forms.Label; $l.Text = $label; $l.Location = New-Object System.Drawing.Point(16, ($script:row + 4)); $l.Size = '120,22'
        $ctrl.Location = New-Object System.Drawing.Point(140, $script:row); $ctrl.Width = $w
        $d.Controls.Add($l); $d.Controls.Add($ctrl); $script:row += 38
    }
    $tName = New-Object System.Windows.Forms.TextBox; Add-Row 'Name' $tName
    $tUrl  = New-Object System.Windows.Forms.TextBox; Add-Row 'Base URL' $tUrl
    $tKey  = New-Object System.Windows.Forms.TextBox; $tKey.UseSystemPasswordChar = $true; Add-Row 'API key' $tKey
    $cModel = New-Object System.Windows.Forms.ComboBox; $cModel.DropDownStyle = 'DropDown'; Add-Row 'Model' $cModel 250
    $bFetch = New-Object System.Windows.Forms.Button; $bFetch.Text = 'Fetch list'; $bFetch.Location = New-Object System.Drawing.Point(398, ($script:row - 39)); $bFetch.Size = '82,27'; $d.Controls.Add($bFetch)
    $cEff = New-Object System.Windows.Forms.ComboBox; $cEff.DropDownStyle = 'DropDownList'; [void]$cEff.Items.AddRange(@('(default)', 'low', 'medium', 'high', 'xhigh')); Add-Row 'Reasoning' $cEff 120
    $hint = New-Object System.Windows.Forms.Label; $hint.ForeColor = [System.Drawing.Color]::Gray
    $hint.Location = New-Object System.Drawing.Point(140, ($script:row - 10)); $hint.Size = '350,20'
    $d.Controls.Add($hint)

    if ($existing) {
        $tName.Text = $existing.name; $tName.ReadOnly = $true
        $tUrl.Text = $existing.baseUrl; $cModel.Text = $existing.model
        $hint.Text = 'Leave the key empty to keep the saved one.'
        $cEff.SelectedItem = $(if ($existing.effort) { [string]$existing.effort } else { '(default)' })
    } else { $tUrl.Text = 'https://'; $cEff.SelectedIndex = 0; $hint.Text = 'Keys are encrypted with your Windows account.' }

    $bFetch.Add_Click({
        try {
            $d.Cursor = 'WaitCursor'
            if ($tKey.Text) { $ids = & $Cli models -BaseUrl $tUrl.Text.Trim() -Key $tKey.Text.Trim() }
            elseif ($existing) { $ids = & $Cli models $existing.name }
            else { throw 'Enter the Base URL and API key first.' }
            $cur = $cModel.Text; $cModel.Items.Clear(); foreach ($i in @($ids)) { [void]$cModel.Items.Add([string]$i) }
            if ($cur) { $cModel.Text = $cur } elseif ($cModel.Items.Count) { $cModel.SelectedIndex = 0 }
            $hint.Text = "$($cModel.Items.Count) models found."; $cModel.DroppedDown = $true
        } catch { [void][System.Windows.Forms.MessageBox]::Show($d, $_.Exception.Message, 'Fetch models failed', 'OK', 'Warning') }
        finally { $d.Cursor = 'Default' }
    })

    $ok = New-Object System.Windows.Forms.Button; $ok.Text = 'Save'; $ok.Location = '300,240'; $ok.Size = '88,30'
    $cancel = New-Object System.Windows.Forms.Button; $cancel.Text = 'Cancel'; $cancel.Location = '396,240'; $cancel.Size = '88,30'; $cancel.DialogResult = 'Cancel'
    $d.Controls.Add($ok); $d.Controls.Add($cancel); $d.AcceptButton = $ok; $d.CancelButton = $cancel
    $ok.Add_Click({
        $argList = @('add', $tName.Text.Trim(), '-BaseUrl', $tUrl.Text.Trim(), '-Model', $cModel.Text.Trim())
        $eff = [string]$cEff.SelectedItem; $argList += @('-Effort', $(if ($eff -eq '(default)') { '' } else { $eff }))
        if ($tKey.Text) { $argList += @('-Key', $tKey.Text.Trim()) } else { $argList += '-KeepKey' }
        if (-not $tName.Text.Trim() -or -not $cModel.Text.Trim()) { [void][System.Windows.Forms.MessageBox]::Show($d, 'Name and Model are required.', 'Add API'); return }
        if (Invoke-Cli $argList) { $d.DialogResult = 'OK'; $d.Close() }
        else { [void][System.Windows.Forms.MessageBox]::Show($d, 'Could not save - see the log in the main window.', 'Add API', 'OK', 'Warning') }
    })
    [void]$d.ShowDialog($form)
}

# ------------------------------------------------------------------ actions
function Restart-Arg { if ($chkRestart.Checked) { @('-Restart') } else { @() } }
function Need-Selection { $n = Selected-Name; if (-not $n) { [void][System.Windows.Forms.MessageBox]::Show($form, 'Select an API in the list first.', 'Codex API Switch') }; return $n }

$btnUse.Add_Click({ $n = Need-Selection; if ($n) { [void](Invoke-Cli (@('use', $n) + (Restart-Arg))) } })
$list.Add_DoubleClick({ $n = Selected-Name; if ($n) { [void](Invoke-Cli (@('use', $n) + (Restart-Arg))) } })
$btnOff.Add_Click({ [void](Invoke-Cli (@('off') + (Restart-Arg))) })
$btnAdd.Add_Click({ Show-ProfileDialog $null })
$btnEdit.Add_Click({ $n = Need-Selection; if ($n) { Show-ProfileDialog (Get-Profiles | Where-Object { $_.name -eq $n } | Select-Object -First 1) } })
$btnTest.Add_Click({ $n = Need-Selection; if ($n) { Add-Log "Testing $n (can take up to a minute)..."; [void](Invoke-Cli @('test', $n)) } })
$btnRefresh.Add_Click({ [void](Invoke-Cli (@('refresh') + (Restart-Arg))) })
$btnRemove.Add_Click({
    $n = Need-Selection; if (-not $n) { return }
    $st = Read-Json $StatePath
    if ($st -and $st.active -eq $n) {
        $r = [System.Windows.Forms.MessageBox]::Show($form, "'$n' is in use. Switch back to ChatGPT and remove it?", 'Remove API', 'YesNo', 'Question')
        if ($r -ne 'Yes') { return }
        if (-not (Invoke-Cli (@('off') + (Restart-Arg)))) { return }
    } else {
        $r = [System.Windows.Forms.MessageBox]::Show($form, "Remove '$n' and its saved key?", 'Remove API', 'YesNo', 'Question')
        if ($r -ne 'Yes') { return }
    }
    [void](Invoke-Cli @('remove', $n))
})
$btnPurge.Add_Click({
    $r = [System.Windows.Forms.MessageBox]::Show($form,
        "This switches Codex back to your ChatGPT login and deletes ALL saved APIs, keys and backups made by this tool.`r`n`r`nContinue?",
        'Remove everything', 'YesNo', 'Warning', 'Button2')
    if ($r -eq 'Yes') { [void](Invoke-Cli (@('purge', '-Yes') + (Restart-Arg))) }
})

Refresh-View
if ($env:CODEX_SWITCH_GUI_SMOKE) { $form.Add_Shown({ [Console]::Out.WriteLine("shown; status='$($status.Text)'; rows=$($list.Items.Count)"); $form.Close() }) }
Add-Log "Config: $(Join-Path $CodexHome 'config.toml')"
# While an API is on, pick up models it added or dropped since the last switch (no app restart here).
if ((Read-Json $StatePath) -and -not $env:CODEX_SWITCH_GUI_SMOKE) {
    $form.Add_Shown({ Add-Log 'Checking the active API for model changes...'; [void](Invoke-Cli @('refresh')) })
}
[void]$form.ShowDialog()
